defmodule HelmsmanDaemon.RepoRequests do
  @moduledoc """
  Runs web requests for local repositories (`repo_browse`, `repo_register`,
  `repo_remove`) outside the connection process, one at a time.

  - A request arriving while another runs is answered `busy`.
  - The last 64 request IDs are remembered; a repeated ID is ignored.
  - A task running longer than 30 s is killed and answered `busy`; the config
    lock dies with it and `config.toml` is replaced atomically.
  - Results go to `Connection.repo_result/2`; `sync?` is true only after a
    successful registration or removal.

  Options: `:task_supervisor`, `:deliver` (`fn report, sync? -> … end`),
  `:request_timeout_ms`, and the options of `HelmsmanDaemon.LocalRepos`.
  """
  use GenServer
  require Logger
  alias HelmsmanDaemon.{Connection, LocalRepos}
  alias HelmsmanProtocol.{Event, Push, Report}

  @remembered 64

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Queues a decoded push; never blocks the caller."
  def submit(push), do: GenServer.cast(__MODULE__, {:submit, push})

  @impl true
  def init(opts) do
    {:ok,
     %{
       opts: opts,
       running: nil,
       seen: :queue.new(),
       seen_set: MapSet.new()
     }}
  end

  @impl true
  def handle_cast({:submit, push}, state) do
    cond do
      MapSet.member?(state.seen_set, push.request_id) ->
        Logger.debug("Ignoring repeated web request #{push.request_id}")
        {:noreply, state}

      state.running ->
        state = remember(state, push.request_id)
        deliver(state, failure(push, :busy, "another request is running on the machine"), false)
        {:noreply, state}

      true ->
        {:noreply, state |> remember(push.request_id) |> start(push)}
    end
  end

  @impl true
  def handle_info({ref, {report, sync?}}, %{running: %{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    deliver(state, report, sync?)
    {:noreply, finish(state)}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{running: %{ref: ref} = running} = state) do
    Logger.error("Web request #{running.push.request_id} failed: #{inspect(reason)}")
    deliver(state, failure(running.push, :busy, "request failed on the machine"), false)
    {:noreply, finish(state)}
  end

  def handle_info({:request_timeout, ref}, %{running: %{ref: ref} = running} = state) do
    Process.demonitor(ref, [:flush])
    Process.exit(running.pid, :kill)
    Logger.warning("Web request #{running.push.request_id} timed out")
    deliver(state, failure(running.push, :busy, "request timed out on the machine"), false)
    {:noreply, finish(state)}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp start(state, push) do
    opts = state.opts
    supervisor = Keyword.get(opts, :task_supervisor, HelmsmanDaemon.RepoTaskSupervisor)
    task = Task.Supervisor.async_nolink(supervisor, fn -> execute(push, opts) end)

    timer =
      Process.send_after(
        self(),
        {:request_timeout, task.ref},
        Keyword.get(opts, :request_timeout_ms, 30_000)
      )

    %{state | running: %{ref: task.ref, pid: task.pid, push: push, timer: timer}}
  end

  defp finish(state) do
    Process.cancel_timer(state.running.timer)
    %{state | running: nil}
  end

  defp remember(state, id) do
    seen = :queue.in(id, state.seen)
    set = MapSet.put(state.seen_set, id)

    if :queue.len(seen) > @remembered do
      {{:value, old}, seen} = :queue.out(seen)
      %{state | seen: seen, seen_set: MapSet.delete(set, old)}
    else
      %{state | seen: seen, seen_set: set}
    end
  end

  defp deliver(state, report, sync?) do
    Keyword.get(state.opts, :deliver, &Connection.repo_result/2).(report, sync?)
  end

  @doc false
  def execute(%Push.RepoBrowse{} = push, opts) do
    case LocalRepos.browse(opts) do
      {:ok, result} ->
        Logger.info(
          "Listed #{length(result.repositories)} local repositories for web request #{push.request_id}"
        )

        {%Report.RepoBrowseResult{
           request_id: push.request_id,
           error: nil,
           message: nil,
           roots: result.roots,
           repositories: result.repositories,
           truncated: result.truncated
         }, false}

      {:error, code} ->
        Logger.info("Web request #{push.request_id} to list local repositories refused: #{code}")
        message = if code == :busy, do: "listing timed out on the machine"
        {failure(push, code, message), false}
    end
  end

  def execute(%Push.RepoRegister{} = push, opts),
    do: change(push, :register, LocalRepos.register_from_web(push, opts))

  def execute(%Push.RepoRemove{} = push, opts),
    do: change(push, :remove, LocalRepos.remove_from_web(push, opts))

  defp change(push, action, :ok),
    do: {change_report(push, action, nil, nil), true}

  defp change(push, action, {:error, code, message}),
    do: {change_report(push, action, code, message), false}

  defp change_report(push, action, error, message) do
    %Report.RepoChangeResult{
      request_id: push.request_id,
      action: action,
      name: push.name,
      error: error,
      message: bounded(message)
    }
  end

  defp failure(%Push.RepoBrowse{} = push, code, message) do
    %Report.RepoBrowseResult{
      request_id: push.request_id,
      error: code,
      message: bounded(message),
      roots: [],
      repositories: [],
      truncated: false
    }
  end

  defp failure(%Push.RepoRegister{} = push, code, message),
    do: change_report(push, :register, code, message)

  defp failure(%Push.RepoRemove{} = push, code, message),
    do: change_report(push, :remove, code, message)

  defp bounded(nil), do: nil
  defp bounded(message), do: message |> Event.truncate(1_024) |> elem(0)
end
