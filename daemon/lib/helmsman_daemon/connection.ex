defmodule HelmsmanDaemon.Connection do
  @moduledoc "Authenticated Channel connection, reconciliation and ordered report retries."
  use Slipstream
  require Logger

  alias HelmsmanDaemon.{
    Cleanup,
    Config,
    Credentials,
    Detector,
    LocalMergeCheck,
    LocalRepos,
    Login,
    Runs
  }

  alias HelmsmanProtocol.ErrorReply
  alias HelmsmanProtocol.Messages
  alias HelmsmanProtocol.Reply
  alias HelmsmanProtocol.Report
  @backoff [1_000, 2_000, 5_000, 10_000, 30_000]

  def child_spec(opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}, restart: :transient}
  end

  def start_link(opts), do: Slipstream.start_link(__MODULE__, opts, name: __MODULE__)

  def report(id, payload) do
    ref = make_ref()
    GenServer.cast(__MODULE__, {:report, id, payload, self(), ref})
    ref
  end

  def cleanup_check(items) do
    GenServer.call(__MODULE__, {:cleanup_check, items}, 35_000)
  end

  def claim, do: GenServer.cast(__MODULE__, :claim)

  @doc "Sends a `repo_status` report when joined; dropped otherwise (the next check resends)."
  def repo_status(%Report.RepoStatus{} = payload),
    do: GenServer.cast(__MODULE__, {:repo_status, payload})

  def active_runs, do: Runs.active()

  @impl true
  def init(opts) do
    case credentials(opts) do
      {:ok, credentials} ->
        socket =
          new_socket()
          |> assign(
            credentials: credentials,
            opts: opts,
            joined?: false,
            queues: %{},
            pending: %{},
            runtimes: [],
            reconnect_attempt: 0,
            dirty_credentials?: false,
            claim_ref: nil,
            rotate_ref: nil,
            control_refs: %{},
            cleanup_refs: %{},
            protocol_version: Keyword.get(opts, :protocol_version, HelmsmanProtocol.version()),
            stopping?: false,
            config_stamp: nil,
            reported_served: nil
          )

        Process.send_after(self(), :periodic, Keyword.get(opts, :heartbeat_interval_ms, 30_000))

        Process.send_after(
          self(),
          :rotation_check,
          Keyword.get(opts, :rotation_interval_ms, 3_600_000)
        )

        Process.send_after(self(), :config_check, config_interval(opts))
        {:ok, socket, {:continue, :connect}}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  defp credentials(opts) do
    case Keyword.fetch(opts, :credentials) do
      {:ok, credentials} -> {:ok, credentials}
      :error -> Credentials.read()
    end
  end

  @impl true
  def handle_continue(:connect, socket), do: connect_socket(socket)

  defp connect_socket(socket) do
    credentials = socket.assigns.credentials
    uri = URI.parse(credentials.server_url)

    uri = %{
      uri
      | scheme: if(uri.scheme == "https", do: "wss", else: "ws"),
        path: HelmsmanProtocol.socket_path() <> "/websocket",
        query: nil,
        fragment: nil,
        userinfo: nil
    }

    opts = [
      uri: uri,
      headers: [{HelmsmanProtocol.token_header(), credentials.token}],
      reconnect_after_msec: @backoff,
      rejoin_after_msec: @backoff,
      test_mode?: Keyword.get(socket.assigns.opts, :test_mode?, false)
    ]

    case connect(socket, opts) do
      {:ok, next} -> {:noreply, next}
      {:error, _reason} -> {:noreply, schedule_reconnect(socket)}
    end
  end

  @impl true
  def handle_connect(socket) do
    {local, socket} = local_repositories(socket)

    payload = %Report.Join{
      protocol: socket.assigns.protocol_version,
      machine: Login.machine(),
      clis: Detector.inventory(),
      max_concurrency: Config.get().max_concurrency,
      active_runs: Runs.active(),
      local_repositories: local
    }

    {:ok, {"join", wire}} = Messages.encode(payload, socket.assigns.protocol_version)
    {:ok, join(assign(socket, :reconnect_attempt, 0), topic(socket), wire)}
  end

  defp local_repositories(socket) do
    if socket.assigns.protocol_version >= HelmsmanProtocol.local_repositories_version() do
      served = served_ids(socket)

      socket =
        socket
        |> assign(:config_stamp, config_stamp())
        |> assign(:reported_served, served)

      {LocalRepos.report(served), socket}
    else
      {nil, socket}
    end
  end

  # Workspaces from the latest reply (state/workspaces.json), else those chosen at login.
  defp served_ids(socket) do
    case LocalRepos.served() do
      nil ->
        case Enum.map(socket.assigns.credentials.workspaces, & &1["id"]) do
          [] -> nil
          ids -> ids
        end

      served ->
        Enum.map(served, & &1.id)
    end
  end

  defp config_stamp do
    case File.stat(LocalRepos.config_path(), time: :posix) do
      {:ok, stat} -> {stat.mtime, stat.size, stat.inode}
      _ -> nil
    end
  end

  defp config_interval(opts), do: Keyword.get(opts, :config_check_interval_ms, 30_000)

  # Records the served workspaces and the merge watch lists of a join / sync reply;
  # a changed set of served workspaces is reported again with `sync`.
  defp apply_local(socket, reply) do
    case LocalRepos.write_served(reply.runtimes) do
      :ok -> :ok
      _ -> Logger.error("Could not write #{LocalRepos.served_path()}")
    end

    if reply.local_repositories, do: LocalMergeCheck.update(reply.local_repositories)

    if socket.assigns.protocol_version >= HelmsmanProtocol.local_repositories_version() and
         served_ids(socket) != socket.assigns.reported_served and
         match?({:ok, [_ | _]}, LocalRepos.entries()),
       do: GenServer.cast(self(), :sync)

    socket
  end

  @impl true
  def handle_join(_topic, payload, socket) do
    case Messages.decode_reply("join", payload) do
      {:ok, reply} ->
        terminate_ids(reply.terminate_run_ids)
        next = socket |> assign(:joined?, true) |> assign(:runtimes, reply.runtimes)
        Cleanup.joined(socket.assigns.protocol_version)
        next = apply_local(next, reply)
        send(self(), :rotation_check_now)
        {:ok, next |> maybe_claim() |> pump_all()}

      _ ->
        fatal(socket, 4, "Invalid join response")
    end
  end

  @impl true
  def handle_topic_close(_topic, reason, socket) do
    case decode_error(reason) do
      {:ok, %ErrorReply{reason: :unsupported_protocol} = error} ->
        fatal(
          socket,
          4,
          "Protocol incompatible: server #{error.server_version}, minimum #{error.min_version}; #{error.upgrade_url}"
        )

      _ ->
        disconnect(socket)
        {:ok, socket |> requeue() |> schedule_reconnect()}
    end
  end

  @impl true
  def handle_leave(_topic, %{assigns: %{stopping?: true}} = socket), do: {:ok, socket}

  def handle_leave(topic, socket), do: handle_topic_close(topic, :left, socket)

  @impl true
  def handle_disconnect(reason, socket) do
    if auth_failure?(reason) do
      fatal(socket, 3, "Authentication failed; login again")
    else
      {:ok, socket |> requeue() |> schedule_reconnect()}
    end
  end

  defp auth_failure?(%{status_code: status}) when status in [401, 403], do: true
  defp auth_failure?(%{status: status}) when status in [401, 403], do: true
  defp auth_failure?({:upgrade_failed, %{status: status}}) when status in [401, 403], do: true

  defp auth_failure?(reason) when is_tuple(reason),
    do: reason |> Tuple.to_list() |> Enum.any?(&auth_failure?/1)

  defp auth_failure?(status) when status in [401, 403], do: true
  defp auth_failure?(_), do: false

  defp schedule_reconnect(socket) do
    attempt = socket.assigns.reconnect_attempt

    delay =
      Enum.at(Keyword.get(socket.assigns.opts, :reconnect_after_ms, @backoff), attempt, 30_000)

    Logger.info("Daemon disconnected; reconnecting in #{delay} ms")
    Process.send_after(self(), :reconnect, delay)
    assign(socket, :reconnect_attempt, attempt + 1)
  end

  defp requeue(socket) do
    Cleanup.disconnected()

    Enum.each(socket.assigns.cleanup_refs, fn {_, caller} ->
      GenServer.reply(caller, {:error, :disconnected})
    end)

    queues =
      Enum.reduce(socket.assigns.pending, socket.assigns.queues, fn {_ref, entry}, queues ->
        Map.update(queues, entry.id, [entry], &[entry | &1])
      end)

    socket
    |> assign(:joined?, false)
    |> assign(:queues, queues)
    |> assign(:pending, %{})
    |> assign(:control_refs, %{})
    |> assign(:cleanup_refs, %{})
    |> assign(:claim_ref, nil)
    |> assign(:rotate_ref, nil)
  end

  @impl true
  def handle_call({:cleanup_check, items}, caller, socket) do
    with true <- socket.assigns.joined?,
         {:ok, report} <- Report.CleanupCheck.new(items: items),
         {:ok, {"cleanup_check", wire}} <-
           Messages.encode(report, socket.assigns.protocol_version),
         {:ok, ref} <- push(socket, topic(socket), "cleanup_check", wire) do
      arm_timeout(ref, socket)
      {:noreply, assign(socket, :cleanup_refs, Map.put(socket.assigns.cleanup_refs, ref, caller))}
    else
      false -> {:reply, {:error, :disconnected}, socket}
      error -> {:reply, error, socket}
    end
  end

  @impl true
  def handle_cast({:report, id, payload, caller, ref}, socket) do
    entry = %{
      id: id,
      payload: payload,
      caller: caller,
      ref: ref,
      attempts: 0,
      available_at: System.monotonic_time(:millisecond),
      event: nil
    }

    queues = Map.update(socket.assigns.queues, id, [entry], &(&1 ++ [entry]))
    {:noreply, socket |> assign(:queues, queues) |> pump(id)}
  end

  def handle_cast(:claim, socket), do: {:noreply, maybe_claim(socket)}
  def handle_cast(:sync, socket), do: {:noreply, sync(socket)}

  def handle_cast({:repo_status, payload}, socket) do
    if socket.assigns.joined? and
         socket.assigns.protocol_version >= HelmsmanProtocol.local_repositories_version(),
       do: {:noreply, control(socket, "repo_status", payload)},
       else: {:noreply, socket}
  end

  @impl true
  def handle_info(:reconnect, %{assigns: %{stopping?: false}} = socket),
    do: connect_socket(socket)

  def handle_info(:periodic, socket) do
    Process.send_after(
      self(),
      :periodic,
      Keyword.get(socket.assigns.opts, :heartbeat_interval_ms, 30_000)
    )

    next =
      if socket.assigns.joined?,
        do: control(socket, "heartbeat", %Report.Heartbeat{runs: Runs.active()}),
        else: socket

    {:noreply, maybe_claim(next)}
  end

  def handle_info(:rotation_check, socket) do
    Process.send_after(
      self(),
      :rotation_check,
      Keyword.get(socket.assigns.opts, :rotation_interval_ms, 3_600_000)
    )

    {:noreply, rotate(socket)}
  end

  def handle_info(:rotation_check_now, socket), do: {:noreply, rotate(socket)}

  def handle_info(:config_check, socket) do
    Process.send_after(self(), :config_check, config_interval(socket.assigns.opts))

    if socket.assigns.joined? and
         socket.assigns.protocol_version >= HelmsmanProtocol.local_repositories_version() and
         config_stamp() != socket.assigns.config_stamp,
       do: {:noreply, sync(socket)},
       else: {:noreply, socket}
  end

  def handle_info({:retry, id}, socket), do: {:noreply, pump(socket, id)}

  def handle_info({:push_timeout, ref}, socket) do
    if Map.has_key?(socket.assigns.pending, ref) or
         Map.has_key?(socket.assigns.control_refs, ref) or
         Map.has_key?(socket.assigns.cleanup_refs, ref),
       do: timeout_reply(ref, socket),
       else: {:noreply, socket}
  end

  def handle_info(_, socket), do: {:noreply, socket}

  defp timeout_reply(ref, socket) do
    {:ok, next} = handle_reply(ref, {:error, :timeout}, socket)
    {:noreply, next}
  end

  @impl true
  def handle_reply(ref, reply, socket) do
    cond do
      Map.has_key?(socket.assigns.cleanup_refs, ref) -> cleanup_reply(ref, reply, socket)
      Map.has_key?(socket.assigns.pending, ref) -> report_reply(ref, reply, socket)
      Map.has_key?(socket.assigns.control_refs, ref) -> control_reply(ref, reply, socket)
      true -> {:ok, socket}
    end
  end

  defp cleanup_reply(ref, reply, socket) do
    {caller, refs} = Map.pop(socket.assigns.cleanup_refs, ref)
    GenServer.reply(caller, decode_reply("cleanup_check", reply))
    {:ok, assign(socket, :cleanup_refs, refs)}
  end

  defp report_reply(ref, reply, socket) do
    {entry, pending} = Map.pop(socket.assigns.pending, ref)
    socket = assign(socket, :pending, pending)

    case decode_reply(entry.event, reply) do
      {:ok, result} ->
        send(entry.caller, {:report_result, entry.ref, {:ok, result}})
        {:ok, pump(socket, entry.id)}

      {:error, %ErrorReply{} = error} when entry.event in ["git_token", "pushed"] ->
        send(entry.caller, {:report_result, entry.ref, {:error, error}})
        {:ok, pump(socket, entry.id)}

      {:error, %ErrorReply{reason: reason} = error} when reason in [:not_found, :wrong_state] ->
        Runs.terminate(entry.id)
        send(entry.caller, {:report_result, entry.ref, {:error, error}})
        {:ok, drop_run(socket, entry.id)}

      {:error, %ErrorReply{reason: :invalid_payload} = error} ->
        reject(socket, entry, error.message)

      _ ->
        {:ok, retry_entry(socket, entry)}
    end
  end

  defp decode_reply(event, :ok), do: decode_reply(event, {:ok, %{}})
  defp decode_reply(event, :error), do: decode_reply(event, {:error, %{}})
  defp decode_reply(event, {:ok, payload}), do: Messages.decode_reply(event, payload)

  defp decode_reply(_event, {:error, payload}) when is_map(payload) do
    case ErrorReply.from_wire(payload) do
      {:ok, error} -> {:error, error}
      _ -> {:error, :invalid_reply}
    end
  end

  defp decode_reply(_event, _), do: {:error, :transport}
  defp decode_error(%{response: response}), do: decode_error(response)
  defp decode_error({:failed_to_join, payload}), do: decode_error(payload)
  defp decode_error({:error, payload}), do: decode_error(payload)
  defp decode_error(payload) when is_map(payload), do: ErrorReply.from_wire(payload)
  defp decode_error(_), do: {:error, :transport}

  defp pump_all(socket), do: Enum.reduce(Map.keys(socket.assigns.queues), socket, &pump(&2, &1))

  defp pump(socket, id) do
    busy? = Enum.any?(socket.assigns.pending, fn {_, entry} -> entry.id == id end)

    case Map.get(socket.assigns.queues, id, []) do
      [entry | tail] when not busy? ->
        if socket.assigns.joined? and entry.available_at <= System.monotonic_time(:millisecond) do
          socket = assign(socket, :queues, Map.put(socket.assigns.queues, id, tail))
          push_entry(socket, entry)
        else
          socket
        end

      _ ->
        socket
    end
  end

  defp push_entry(socket, entry) do
    case Messages.encode(entry.payload, socket.assigns.protocol_version) do
      {:ok, {event, wire}} ->
        case push(socket, topic(socket), event, wire) do
          {:ok, ref} ->
            arm_timeout(ref, socket)

            assign(
              socket,
              :pending,
              Map.put(socket.assigns.pending, ref, %{entry | event: event})
            )

          _ ->
            retry_entry(socket, entry)
        end

      {:error, _} ->
        {:ok, next} = reject(socket, entry, "local encoding failed")
        next
    end
  end

  defp retry_entry(socket, entry) do
    if match?(%Report.Finished{}, entry.payload) and entry.attempts >= 3 do
      Logger.error("Finished report retry limit reached for run #{entry.id}")
      send(entry.caller, {:report_result, entry.ref, {:error, :retry_exhausted}})
      socket
    else
      backoff = Keyword.get(socket.assigns.opts, :report_backoff_ms, @backoff)
      delay = Enum.at(backoff, entry.attempts, List.last(backoff))

      entry = %{
        entry
        | attempts: entry.attempts + 1,
          available_at: System.monotonic_time(:millisecond) + delay
      }

      queues = Map.update(socket.assigns.queues, entry.id, [entry], &[entry | &1])
      Process.send_after(self(), {:retry, entry.id}, delay)
      assign(socket, :queues, queues)
    end
  end

  defp reject(socket, entry, reason) do
    Logger.error("Daemon report rejected for run #{entry.id}: invalid_payload")
    send(entry.caller, {:report_rejected, :invalid_payload, reason})
    {:ok, drop_run(socket, entry.id)}
  end

  defp drop_run(socket, id) do
    pending = Map.reject(socket.assigns.pending, fn {_, entry} -> entry.id == id end)
    socket |> assign(:queues, Map.delete(socket.assigns.queues, id)) |> assign(:pending, pending)
  end

  defp maybe_claim(socket) do
    if socket.assigns.joined? and is_nil(socket.assigns.claim_ref) and Runs.free_slots() > 0,
      do: control(socket, "claim", %Report.Claim{}),
      else: socket
  end

  defp sync(socket) do
    if socket.assigns.joined? do
      {local, socket} = local_repositories(socket)

      payload = %Report.Sync{
        machine: Login.machine(),
        clis: Detector.inventory(),
        max_concurrency: Config.get().max_concurrency,
        local_repositories: local
      }

      control(socket, "sync", payload)
    else
      socket
    end
  end

  defp control(socket, event, payload) do
    {:ok, {^event, wire}} = Messages.encode(payload, socket.assigns.protocol_version)

    case push(socket, topic(socket), event, wire) do
      {:ok, ref} ->
        arm_timeout(ref, socket)
        socket = assign(socket, :control_refs, Map.put(socket.assigns.control_refs, ref, event))

        case event do
          "claim" -> assign(socket, :claim_ref, ref)
          "rotate_token" -> assign(socket, :rotate_ref, ref)
          _ -> socket
        end

      _ ->
        socket
    end
  end

  defp control_reply(ref, reply, socket) do
    {event, refs} = Map.pop(socket.assigns.control_refs, ref)
    socket = assign(socket, :control_refs, refs)

    socket =
      case event do
        "claim" -> assign(socket, :claim_ref, nil)
        "rotate_token" -> assign(socket, :rotate_ref, nil)
        _ -> socket
      end

    {:ok, apply_control(event, decode_reply(event, reply), socket)}
  end

  defp apply_control("claim", {:ok, %Reply.Claim{runs: runs}}, socket) do
    opts =
      socket.assigns.opts
      |> Keyword.get(:run_worker_opts, [])
      |> Keyword.put(:server_url, socket.assigns.credentials.server_url)

    Enum.each(runs, &Runs.start_run(&1, opts))
    if runs == [], do: socket, else: maybe_claim(socket)
  end

  defp apply_control(event, {:ok, %{terminate_run_ids: ids} = reply}, socket)
       when event in ["sync", "heartbeat"] do
    terminate_ids(ids)

    if event == "sync",
      do: socket |> assign(:runtimes, reply.runtimes) |> apply_local(reply),
      else: socket
  end

  defp apply_control("rotate_token", {:ok, %Reply.RotateToken{token: token}}, socket) do
    credentials = %{socket.assigns.credentials | token: token, issued_at: now(socket)}
    socket |> assign(:credentials, credentials) |> persist_credentials()
  end

  defp apply_control(_event, _reply, socket), do: socket

  defp rotate(socket) do
    cond do
      not socket.assigns.joined? ->
        socket

      socket.assigns.dirty_credentials? ->
        persist_credentials(socket)

      socket.assigns.rotate_ref != nil ->
        socket

      DateTime.diff(now(socket), socket.assigns.credentials.issued_at) >= 30 * 86_400 ->
        control(socket, "rotate_token", %Report.RotateToken{})

      true ->
        socket
    end
  end

  defp persist_credentials(socket) do
    writer = Keyword.get(socket.assigns.opts, :credentials_writer, &Credentials.write/1)

    case writer.(socket.assigns.credentials) do
      :ok ->
        assign(socket, :dirty_credentials?, false)

      _ ->
        Logger.error("Could not persist rotated daemon credentials; will retry")
        assign(socket, :dirty_credentials?, true)
    end
  end

  defp now(socket), do: Keyword.get(socket.assigns.opts, :clock, &DateTime.utc_now/0).()

  @impl true
  def handle_message(_topic, event, wire, socket) do
    case Messages.decode(event, wire) do
      {:ok, %HelmsmanProtocol.Push.RunsAvailable{}} ->
        {:ok, maybe_claim(socket)}

      {:ok, %HelmsmanProtocol.Push.ConfigChanged{}} ->
        {:ok, sync(socket)}

      {:ok, %HelmsmanProtocol.Push.Cancel{run_id: id}} ->
        Runs.cancel(id)
        {:ok, socket}

      {:ok, %HelmsmanProtocol.Push.Revoked{}} ->
        Credentials.delete()
        fatal(socket, 3, "Daemon token revoked; login again")

      {:ok, %HelmsmanProtocol.Push.Steer{run_id: id, feedback_id: feedback_id, text: text}} ->
        Runs.steer(id, feedback_id, text)
        {:ok, socket}

      _ ->
        Logger.error("Invalid daemon push")
        {:ok, socket}
    end
  end

  defp terminate_ids(ids), do: Enum.each(ids, &Runs.terminate/1)
  defp topic(socket), do: HelmsmanProtocol.topic(socket.assigns.credentials.daemon_id)

  defp arm_timeout(ref, socket),
    do:
      Process.send_after(
        self(),
        {:push_timeout, ref},
        Keyword.get(socket.assigns.opts, :push_timeout_ms, 15_000)
      )

  defp fatal(socket, code, message) do
    IO.puts(message)
    Runs.terminate_all()
    # Allow the worker interrupt and escalation to finish before stopping the VM.
    stop = Keyword.get(socket.assigns.opts, :stop, &System.stop/1)

    spawn(fn ->
      await_runs(Keyword.get(socket.assigns.opts, :fatal_grace_ms, 11_000))
      stop.(code)
    end)

    {:stop, :normal, assign(socket, :stopping?, true)}
  end

  defp await_runs(remaining) when remaining <= 0, do: :ok

  defp await_runs(remaining) do
    if Runs.active() != [] do
      Process.sleep(50)
      await_runs(remaining - 50)
    end
  end
end
