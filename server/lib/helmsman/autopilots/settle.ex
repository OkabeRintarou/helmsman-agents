defmodule Helmsman.Autopilots.Settle do
  @moduledoc """
  Settling the started record of an autopilot (`add-autopilots`
  decision 8): idempotent, decided with the autopilot row locked
  `FOR UPDATE`; tasks and runs are read without locks. The mode and the
  target are the record's frozen ones.

  Afterwards, a pending record with nothing started gets its
  `Helmsman.Autopilots.Workers.StartPending` job.
  """

  import Ecto.Query

  alias Helmsman.Autopilots.{Autopilot, Record, State}
  alias Helmsman.Autopilots.Workers.StartPending
  alias Helmsman.Locks
  alias Helmsman.Repo
  alias Helmsman.Runs
  alias Helmsman.Runs.{Retry, Run}
  alias Helmsman.Tasks.Task
  alias Helmsman.Tx

  @retry_alive ~w(available scheduled executing retryable)

  @doc "Settles the autopilot `id` in a transaction of its own."
  @spec settle(pos_integer()) :: {:ok, Autopilot.t() | :gone}
  def settle(id) do
    Tx.run(
      fn ->
        with %Autopilot{workspace_id: ws} <- Repo.get(Autopilot, id),
             :ok <- Locks.maint_shared!(ws),
             %Autopilot{} = autopilot <- State.lock(ws, id) do
          {:ok, settle_locked(autopilot)}
        else
          nil -> {:ok, :gone}
        end
      end,
      retry: 1
    )
  end

  @doc """
  Settles the started record of `autopilot` (locked by the caller) and
  plans the start of a pending one. Returns the autopilot as updated.
  """
  @spec settle_locked(Autopilot.t()) :: Autopilot.t()
  def settle_locked(%Autopilot{} = autopilot) do
    %{started: started, pending: pending} = State.open_records(autopilot.id)

    {autopilot, open?} =
      case started && outcome(started) do
        nil ->
          {autopilot, false}

        :open ->
          {autopilot, true}

        {status, reason, opts} ->
          {autopilot, _record} = State.finish!(autopilot, started, status, reason, opts)
          {autopilot, false}
      end

    if pending && not open? do
      {:ok, _job} = Oban.insert(StartPending.new(%{autopilot_run_id: pending.id}))
    end

    autopilot
  end

  @doc """
  The outcome of the started `record` (pure but for reads): `:open`, or
  `{status, reason, opts}` with the `result`.
  """
  @spec outcome(Record.t()) :: :open | {atom(), atom() | nil, keyword()}
  def outcome(%Record{config: %{"mode" => "run_only"}} = record) do
    case record.run_id && Repo.get(Run, record.run_id) do
      nil -> {:failed, :run_failed, result: "the run no longer exists"}
      %Run{status: :succeeded} = run -> {:succeeded, nil, result: run.summary}
      %Run{status: :failed} = run -> {:failed, :run_failed, result: failure(run)}
      %Run{status: :cancelled} = run -> cancelled(run)
      %Run{} -> :open
    end
  end

  def outcome(%Record{config: %{"mode" => "create_task"}} = record) do
    case record.task_id && Repo.get(Task, record.task_id) do
      nil -> {:cancelled, :task_deleted, []}
      task -> task_outcome(record, task)
    end
  end

  defp task_outcome(record, %Task{} = task) do
    cond do
      task.status in [:done, :verified] -> {:succeeded, nil, []}
      task.status == :rejected -> {:failed, :task_rejected, []}
      task.status == :cancelled -> {:cancelled, :task_cancelled, []}
      task.assignee_id != record.config["agent_id"] -> {:cancelled, :reassigned, []}
      working?(task) -> :open
      true -> last_run_outcome(task)
    end
  end

  defp working?(task) do
    statuses = Run.pending_statuses() ++ Run.active_statuses()
    Repo.exists?(from(r in Run, where: r.task_id == ^task.id and r.status in ^statuses))
  end

  defp last_run_outcome(task) do
    last =
      Repo.one(
        from(r in Run,
          where: r.task_id == ^task.id and r.status in ^Run.ended_statuses(),
          order_by: [desc: r.finished_at, desc: r.id],
          limit: 1
        )
      )

    case last do
      %Run{status: :failed} = run ->
        if will_retry?(run), do: :open, else: {:failed, :run_failed, result: failure(run)}

      %Run{status: :cancelled} = run ->
        cancelled(run)

      _succeeded_or_none ->
        :open
    end
  end

  defp cancelled(run) do
    if Runs.stopped_by_person?(run),
      do: {:cancelled, :stopped, []},
      else: {:failed, :run_failed, result: failure(run)}
  end

  # An automatic retry is still to come: its job is alive or it was
  # requeued already.
  defp will_retry?(%Run{id: id} = run) do
    Retry.automatic?(run) and
      (Repo.exists?(
         from(j in Oban.Job,
           where:
             j.worker == "Helmsman.Runs.Workers.Retry" and j.state in @retry_alive and
               fragment("(?->>'run_id')::bigint", j.args) == ^id
         )
       ) or Repo.exists?(from(r in Run, where: r.retry_of_id == ^id)))
  end

  defp failure(%Run{} = run) do
    reason = run.failure_reason && Atom.to_string(run.failure_reason)

    [reason, run.error && String.slice(run.error, 0, 1000)]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(": ")
    |> case do
      "" -> nil
      text -> text
    end
  end
end
