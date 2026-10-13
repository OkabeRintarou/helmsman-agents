defmodule HelmsmanWeb.DaemonChannel do
  @moduledoc """
  Daemon control messages and authorization-aware disconnects; the run
  messages of `add-run-lifecycle` (decision 18) go to `Helmsman.Runs`.
  """
  use HelmsmanWeb, :channel
  alias Helmsman.{Daemons, LocalRepositories, Repo, Runs}
  alias HelmsmanProtocol.{ErrorReply, Messages, Push, Reply}

  @impl true
  def join("daemon:" <> id, payload, socket) do
    with true <- id == to_string(socket.assigns.daemon_id),
         {:ok, report} <- decode_join(payload),
         true <- HelmsmanProtocol.compatible?(report.protocol),
         {:ok, runtimes} <-
           Daemons.register(socket.assigns.daemon_id, socket.assigns.auth_epoch, report) do
      socket = assign(socket, :protocol, report.protocol)

      {:ok, %{terminate_run_ids: terminate, cancel_run_ids: cancel}} =
        Runs.reconcile(daemon_ctx(socket), Enum.map(report.active_runs, & &1.run_id), :join)

      # After the join reply.
      if cancel != [], do: send(self(), {:push_cancels, cancel})

      {:ok,
       wire_reply(
         "join",
         %Reply.Join{
           daemon_id: socket.assigns.daemon_id,
           runtimes: runtimes,
           terminate_run_ids: terminate,
           local_repositories: local_repositories(socket)
         },
         socket
       ), socket}
    else
      false ->
        if id == to_string(socket.assigns.daemon_id),
          do: {:error, unsupported()},
          else: {:error, error(:not_found)}

      {:error, :busy} ->
        {:error, error(:wrong_state)}

      {:error, reason} when reason in [:revoked, :reauthorized, :not_found] ->
        disconnect(socket)
        {:error, error(:not_found)}

      _ ->
        {:error, error(:invalid_payload)}
    end
  end

  defp decode_join(%{"protocol" => protocol} = payload) when is_integer(protocol) do
    with {:ok, report} <-
           Messages.decode("join", Map.put(payload, "protocol", HelmsmanProtocol.version())) do
      {:ok, %{report | protocol: protocol}}
    end
  end

  defp decode_join(payload), do: Messages.decode("join", payload)

  @impl true
  def handle_in(name, payload, socket) do
    case Messages.decode(name, payload) do
      {:ok, report} -> name |> handle_report(report, socket) |> maybe_drop_reply(name)
      _ -> {:reply, {:error, error(:invalid_payload)}, socket}
    end
  end

  if Mix.env() == :test do
    # Test-only (`add-run-lifecycle` 7.1): for each message name in
    # `config :helmsman, :daemon_channel_drop_replies`, the first reply of
    # the connection is swallowed after the message was handled.
    defp maybe_drop_reply({:reply, reply, socket}, name) do
      dropped = Map.get(socket.assigns, :dropped_replies, MapSet.new())

      if name in Application.get_env(:helmsman, :daemon_channel_drop_replies, []) and
           not MapSet.member?(dropped, name) do
        {:noreply, assign(socket, :dropped_replies, MapSet.put(dropped, name))}
      else
        {:reply, reply, socket}
      end
    end

    defp maybe_drop_reply(result, _name), do: result
  else
    defp maybe_drop_reply(result, _name), do: result
  end

  defp handle_report("sync", report, socket) do
    report =
      if local_repositories?(socket), do: report, else: %{report | local_repositories: nil}

    case Daemons.register(socket.assigns.daemon_id, socket.assigns.auth_epoch, report) do
      {:ok, runtimes} ->
        respond(
          "sync",
          %Reply.Join{
            daemon_id: socket.assigns.daemon_id,
            runtimes: runtimes,
            terminate_run_ids: [],
            local_repositories: local_repositories(socket)
          },
          socket
        )

      {:error, :busy} ->
        {:stop, :normal, {:error, error(:wrong_state)}, socket}

      {:error, reason} when reason in [:revoked, :reauthorized, :not_found] ->
        unauthorized_reply(socket)

      _ ->
        {:reply, {:error, error(:invalid_payload)}, socket}
    end
  end

  defp handle_report("rotate_token", _report, socket) do
    case Daemons.rotate_token(socket.assigns.daemon_id, socket.assigns.auth_epoch) do
      {:ok, token} -> respond("rotate_token", %Reply.RotateToken{token: token}, socket)
      _ -> unauthorized_reply(socket)
    end
  end

  defp handle_report("heartbeat", report, socket) do
    case Daemons.heartbeat(socket.assigns.daemon_id, socket.assigns.auth_epoch) do
      {:ok, _} ->
        {:ok, %{terminate_run_ids: terminate, cancel_run_ids: cancel}} =
          Runs.reconcile(daemon_ctx(socket), Enum.map(report.runs, & &1.run_id), :heartbeat)

        Enum.each(cancel, &push_message(%Push.Cancel{run_id: &1}, socket))
        respond("heartbeat", %Reply.Heartbeat{terminate_run_ids: terminate}, socket)

      _ ->
        unauthorized_reply(socket)
    end
  end

  # Push tokens are fetched before the claim transaction
  # (`add-daemon-git-workspace` decision 2).
  defp handle_report("claim", _report, socket) do
    ctx = daemon_ctx(socket)
    tokens = Runs.prefetch_push_tokens(ctx)

    case Runs.claim(ctx, HelmsmanWeb.Endpoint.url(), tokens) do
      {:ok, specs} -> respond("claim", %Reply.Claim{runs: specs}, socket)
      {:error, reason} -> run_error(reason, socket)
    end
  end

  defp handle_report("starting", report, socket) do
    case Runs.starting(daemon_ctx(socket), report.run_id) do
      {:ok, :proceed} ->
        respond("starting", %Reply.Starting{action: :proceed, reason: nil}, socket)

      {:ok, {:abort, reason}} ->
        respond("starting", %Reply.Starting{action: :abort, reason: reason}, socket)

      {:error, reason} ->
        run_error(reason, socket)
    end
  end

  defp handle_report("started", report, socket) do
    case Runs.started(daemon_ctx(socket), report) do
      :ok -> respond("started", %Reply.Empty{}, socket)
      {:error, reason} -> run_error(reason, socket)
    end
  end

  defp handle_report("events", report, socket) do
    case Runs.append_events(daemon_ctx(socket), report.run_id, report.events) do
      {:ok, acked} -> respond("events", %Reply.Events{acked_seq: acked}, socket)
      {:error, reason} -> run_error(reason, socket)
    end
  end

  defp handle_report("finished", report, socket) do
    case Runs.finish(daemon_ctx(socket), report) do
      :ok -> respond("finished", %Reply.Empty{}, socket)
      {:error, reason} -> run_error(reason, socket)
    end
  end

  defp handle_report("git_token", report, socket) do
    case Runs.git_token(daemon_ctx(socket), report.run_id) do
      {:ok, %{token: token, expires_at: expires_at}} ->
        respond("git_token", %Reply.GitToken{token: token, expires_at: expires_at}, socket)

      {:error, :wrong_state} ->
        {:reply, {:error, error(:wrong_state, "the run ended over 30 minutes ago")}, socket}

      {:error, {:unavailable, message}} ->
        {:reply, {:error, error(:wrong_state, message)}, socket}

      {:error, reason} ->
        run_error(reason, socket)
    end
  end

  defp handle_report("pushed", report, socket) do
    case Runs.pushed(daemon_ctx(socket), report) do
      :ok ->
        respond("pushed", %Reply.Empty{}, socket)

      {:error, :wrong_state} ->
        message = "the run has no repository or another push is recorded for it"
        {:reply, {:error, error(:wrong_state, message)}, socket}

      {:error, reason} ->
        run_error(reason, socket)
    end
  end

  # `add-local-repositories` decision 13; the message exists from protocol 3.
  defp handle_report("repo_status", report, socket) do
    if local_repositories?(socket) do
      case LocalRepositories.apply_status(daemon_ctx(socket), report) do
        :ok -> respond("repo_status", %Reply.Empty{}, socket)
        {:error, reason} -> run_error(reason, socket)
      end
    else
      {:reply, {:error, error(:invalid_payload)}, socket}
    end
  end

  # `steer_ack` comes with `add-run-steering`.
  defp handle_report(_name, _report, socket), do: {:reply, {:error, error(:not_found)}, socket}

  defp run_error(:reauthorized, socket), do: unauthorized_reply(socket)

  defp run_error(reason, socket) when reason in [:not_found, :wrong_state],
    do: {:reply, {:error, error(reason)}, socket}

  defp run_error({:invalid_payload, _detail}, socket),
    do: {:reply, {:error, error(:invalid_payload)}, socket}

  defp local_repositories?(socket),
    do: socket.assigns.protocol >= HelmsmanProtocol.local_repositories_version()

  # The join / sync reply's local repositories (protocol 3; older
  # connections get none, and the encoding leaves the field out).
  defp local_repositories(socket) do
    if local_repositories?(socket),
      do: LocalRepositories.reply_entries(socket.assigns.daemon_id),
      else: nil
  end

  defp daemon_ctx(socket) do
    %{
      daemon_id: socket.assigns.daemon_id,
      user_id: socket.assigns.user_id,
      auth_epoch: socket.assigns.auth_epoch,
      protocol: socket.assigns.protocol
    }
  end

  @impl true
  def handle_info({:runs_available}, socket) do
    push_message(%Push.RunsAvailable{}, socket)
    {:noreply, socket}
  end

  def handle_info({:cancel_run, run_id}, socket) do
    push_message(%Push.Cancel{run_id: run_id}, socket)
    {:noreply, socket}
  end

  def handle_info({:push_cancels, run_ids}, socket) do
    Enum.each(run_ids, &push_message(%Push.Cancel{run_id: &1}, socket))
    {:noreply, socket}
  end

  def handle_info({:daemon_config_changed}, socket) do
    push_message(%Push.ConfigChanged{}, socket)
    {:noreply, socket}
  end

  def handle_info({kind}, socket) when kind in [:daemon_revoked, :daemon_reauthorized] do
    case connection_state(socket) do
      :valid -> {:noreply, socket}
      _ -> stop(socket)
    end
  end

  defp unauthorized_reply(socket) do
    if connection_state(socket) == :revoked, do: push_message(%Push.Revoked{}, socket)
    disconnect(socket)
    {:stop, :normal, {:error, error(:not_found)}, socket}
  end

  defp stop(socket) do
    if connection_state(socket) == :revoked, do: push_message(%Push.Revoked{}, socket)
    disconnect(socket)
    {:stop, :normal, socket}
  end

  defp connection_state(socket) do
    case Repo.get(Daemons.Daemon, socket.assigns.daemon_id) do
      nil -> :reauthorized
      %{revoked_at: revoked} when not is_nil(revoked) -> :revoked
      %{auth_epoch: epoch} when epoch != socket.assigns.auth_epoch -> :reauthorized
      _ -> :valid
    end
  end

  defp disconnect(socket),
    do: HelmsmanWeb.Endpoint.broadcast(HelmsmanWeb.DaemonSocket.id(socket), "disconnect", %{})

  defp push_message(message, socket) do
    {:ok, {name, payload}} = Messages.encode(message, socket.assigns.protocol)
    push(socket, name, payload)
  end

  defp respond(name, reply, socket), do: {:reply, {:ok, wire_reply(name, reply, socket)}, socket}

  defp wire_reply(name, reply, socket) do
    {:ok, payload} = Messages.encode_reply(name, reply, socket.assigns.protocol)
    payload
  end

  defp error(reason) do
    error(
      reason,
      if(reason == :wrong_state,
        do: "state changed concurrently, reconnecting",
        else: Atom.to_string(reason)
      )
    )
  end

  defp error(reason, message) do
    {:ok, reply} = ErrorReply.new(reason, message)
    ErrorReply.to_wire(reply)
  end

  defp unsupported do
    {:ok, reply} =
      ErrorReply.unsupported_protocol(HelmsmanWeb.DaemonDeviceController.upgrade_url())

    ErrorReply.to_wire(reply)
  end
end
