defmodule HelmsmanDaemon.Runs do
  @moduledoc "Registry-based running inventory, monitoring and crash reconciliation."
  use GenServer
  require Logger
  alias HelmsmanDaemon.{Config, RunWorker, StateStore}
  alias HelmsmanProtocol.{ActiveRun, Report.Finished}

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def entries do
    Registry.select(HelmsmanDaemon.RunRegistry, [
      {{:"$1", :"$2", :"$3"}, [], [{{:"$1", :"$2", :"$3"}}]}
    ])
  end

  def active do
    Enum.map(entries(), fn {id, _pid, value} ->
      %ActiveRun{run_id: id, last_seq: value.last_seq}
    end)
  end

  def free_slots, do: max(Config.get().max_concurrency - length(entries()), 0)
  def terminate(id), do: signal(id, :terminate)
  def cancel(id), do: signal(id, :cancel)
  def terminate_all, do: Enum.each(entries(), fn {id, _, _} -> terminate(id) end)

  def signal(id, reason) do
    Enum.each(Registry.lookup(HelmsmanDaemon.RunRegistry, id), fn {pid, _} ->
      GenServer.cast(pid, {:stop, reason})
    end)

    :ok
  end

  @doc "Hands a steering message to the run's worker (`add-run-steering` decision 9)."
  def steer(id, feedback_id, text) do
    case Registry.lookup(HelmsmanDaemon.RunRegistry, id) do
      [] ->
        Logger.debug("Steering for run #{id}, which is not running here")

      workers ->
        Enum.each(workers, fn {pid, _} -> GenServer.cast(pid, {:steer, feedback_id, text}) end)
    end

    :ok
  end

  def start_run(spec, opts \\ []), do: GenServer.call(__MODULE__, {:start_run, spec, opts})

  @impl true
  def init(opts) do
    monitors = Map.new(entries(), fn {id, pid, _} -> {Process.monitor(pid), id} end)
    StateStore.recover(Enum.map(entries(), &elem(&1, 0)))

    {:ok,
     %{
       monitors: monitors,
       reporter:
         Keyword.get(
           opts,
           :reporter,
           Application.get_env(:helmsman_daemon, :reporter, HelmsmanDaemon.Connection)
         )
     }}
  end

  @impl true
  def handle_call({:start_run, spec, opts}, _from, state) do
    if free_slots() > 0 and Registry.lookup(HelmsmanDaemon.RunRegistry, spec.run_id) == [] do
      case DynamicSupervisor.start_child(HelmsmanDaemon.RunSupervisor, {RunWorker, {spec, opts}}) do
        {:ok, pid} ->
          {:reply, {:ok, pid},
           %{state | monitors: Map.put(state.monitors, Process.monitor(pid), spec.run_id)}}

        error ->
          {:reply, error, state}
      end
    else
      {:reply, {:error, :full_or_duplicate}, state}
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    {id, monitors} = Map.pop(state.monitors, ref)

    if id do
      if reason not in [:normal, :shutdown] do
        StateStore.recover_run(id)

        state.reporter.report(id, %Finished{
          run_id: id,
          status: :failed,
          failure_reason: :unknown,
          error: "daemon worker crashed: #{inspect(reason, limit: 5)}",
          session_id: nil,
          summary: nil,
          usage: nil
        })
      end

      if Process.whereis(HelmsmanDaemon.Connection), do: HelmsmanDaemon.Connection.claim()
    end

    {:noreply, %{state | monitors: monitors}}
  end

  def handle_info({:report_rejected, _kind, _reason}, state) do
    Logger.error("Worker crash report rejected")
    {:noreply, state}
  end

  def handle_info({:report_result, _ref, _result}, state), do: {:noreply, state}
end
