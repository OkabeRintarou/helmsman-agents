defmodule Helmsman.Dispatch.Dependencies do
  @moduledoc """
  Runs deferred by a dependency (`add-dependency-dispatch`, designs/13
  §2.4, 07 §2).

  An assignment trigger (`assign`, `reopen`, `resubmit`;
  `Helmsman.Runs.Triggers.dependency_gated?/1`) for a task with an
  unsatisfied prerequisite creates a `deferred` run
  (`Helmsman.Runs.enqueue/3`). It becomes `queued` when every
  prerequisite is satisfied (`release/1`), by one of two paths that never
  lose a wake-up (decision 5):

    * in place, under the workspace graph lock, in the transaction that
      may satisfy a prerequisite: `Helmsman.Links.status_changed/3` (every
      transition, automatic ones included) and removing a `depends_on`;
    * after the commit, for writes made without the graph lock (a run
      claimed or ended, a push, a pull request merged, a local branch
      merged or unmerged, a step attached to or detached from an epic):
      `changed/1` inserts `Helmsman.Dispatch.Workers.ReleaseDependents` in
      that transaction; the job takes the graph lock and releases.

  `Helmsman.Dispatch.Workers.DependencySweep` catches what neither path
  sees (a project bound to another repository) every ten minutes.

  A deferred run is never claimed, so when it becomes obsolete it is
  cancelled where that happens (decision 8): `cancel_reassigned/1` and the
  transition step `after_transition/3`.
  """

  import Ecto.Query, warn: false
  import Helmsman.Runs.Triggers, only: [dependency_gated_sql: 1]

  alias Helmsman.Accounts.Scope
  alias Helmsman.Dispatch.Workers.ReleaseDependents
  alias Helmsman.Links
  alias Helmsman.Locks
  alias Helmsman.Repo
  alias Helmsman.Runs
  alias Helmsman.Runs.Run
  alias Helmsman.Tasks.{Task, TaskEvent}
  alias Helmsman.Tx

  @max_prerequisites 20
  @sweep_batch 500
  @sweep_batches 10
  @closed [:cancelled, :verified]

  ## Releasing

  @doc """
  Releases the runs of each task of `task_ids` (ascending) that wait for
  dependencies (`deferred` with gated triggers), when the task has no
  unsatisfied prerequisite left: `queued`, with an `unblocked` marker
  appended to the triggers (`prerequisites`: the task's `depends_on`
  prerequisites by internal ID, at most #{@max_prerequisites}; no
  authorization source). Priority, `not_before` and `inserted_at` do not
  change; the runtime's daemon is told after the commit.

  The caller holds the workspace graph lock. Deferred runs that do not
  wait for dependencies are left alone.
  """
  @spec release([pos_integer()]) :: :ok
  def release(task_ids) when is_list(task_ids) do
    task_ids |> Enum.uniq() |> Enum.sort() |> Enum.each(&release_task/1)
  end

  defp release_task(task_id) do
    runs =
      Repo.all(
        from(r in Run,
          where:
            r.task_id == ^task_id and r.status == :deferred and
              dependency_gated_sql(r.triggers),
          order_by: r.id,
          lock: "FOR UPDATE"
        )
      )

    if runs != [] and Links.blockers(task_id) == [] do
      marker = %{
        "kind" => "unblocked",
        "prerequisites" => Links.prerequisites(task_id, @max_prerequisites),
        "at" => DateTime.to_iso8601(DateTime.utc_now())
      }

      Enum.each(runs, &unblock!(&1, marker))
    end
  end

  defp unblock!(%Run{id: id, triggers: triggers}, marker) do
    {1, [run]} =
      Repo.update_all(
        from(r in Run, where: r.id == ^id, select: r),
        set: [status: :queued, triggers: triggers ++ [marker], updated_at: DateTime.utc_now()]
      )

    Runs.notify_run(run, available: true)
  end

  @doc """
  Registers a re-check of the tasks depending on `task_id` (decision 6):
  inserts `Helmsman.Dispatch.Workers.ReleaseDependents` in the caller's
  transaction, so it commits or rolls back with the change. Unique per
  task among jobs not yet executing. `nil` does nothing.
  """
  @spec changed(pos_integer() | nil) :: :ok
  def changed(nil), do: :ok

  def changed(task_id) when is_integer(task_id) do
    {:ok, _job} = Oban.insert(ReleaseDependents.new(%{task_id: task_id}))
    :ok
  end

  @doc """
  The tasks whose prerequisites `task_id` may satisfy: those depending on
  it and, when it is a step, those depending on its epic.
  """
  @spec affected(pos_integer()) :: [pos_integer()]
  def affected(task_id) when is_integer(task_id) do
    epic_id = Repo.one(from(t in Task, where: t.id == ^task_id, select: t.epic_id))
    Links.dependents(Enum.reject([task_id, epic_id], &is_nil/1))
  end

  @doc """
  The re-check (`Helmsman.Dispatch.Workers.ReleaseDependents`): in a
  transaction (maintenance lock shared, then the graph lock) releases the
  tasks `affected/1` by `task_id` and, after the commit, sends each of
  them `{:task_updated, summary}` on its project topic and
  `{:links_changed, ident}` on its topic (designs/07 §4). An unknown task
  does nothing.
  """
  @spec recheck(pos_integer()) :: :ok
  def recheck(task_id) when is_integer(task_id) do
    case Repo.one(from(t in Task, where: t.id == ^task_id, select: t.workspace_id)) do
      nil ->
        :ok

      workspace_id ->
        {:ok, :ok} =
          Tx.run(fn ->
            Locks.maint_shared!(workspace_id)
            :ok = Locks.graph!(workspace_id)
            dependents = affected(task_id)
            :ok = release(dependents)
            {:ok, Links.notify_dependents(dependents)}
          end)

        :ok
    end
  end

  @doc """
  Releases every run deferred by a dependency, whatever the dependencies
  (`queued`, no marker), workspace by workspace under the graph lock.
  Only for rolling the code back (Migration Plan): the older code's
  claiming checks them again. Returns how many.
  """
  @spec release_all() :: non_neg_integer()
  def release_all do
    from(r in Run,
      where: r.status == :deferred and dependency_gated_sql(r.triggers),
      distinct: true,
      select: r.workspace_id
    )
    |> Repo.all()
    |> Enum.map(fn workspace_id ->
      {:ok, count} =
        Tx.run(fn ->
          Locks.maint_shared!(workspace_id)
          :ok = Locks.graph!(workspace_id)

          {count, runs} =
            Repo.update_all(
              from(r in Run,
                where:
                  r.workspace_id == ^workspace_id and r.status == :deferred and
                    dependency_gated_sql(r.triggers),
                select: r
              ),
              set: [status: :queued, updated_at: DateTime.utc_now()]
            )

          Enum.each(runs, &Runs.notify_run(&1, available: true))
          {:ok, count}
        end)

      count
    end)
    |> Enum.sum()
  end

  ## Obsolete deferred runs

  @doc """
  The runs on `task` deferred by a dependency for an agent that is no
  longer its assignee are cancelled (`obsolete`), in the caller's
  transaction (`Helmsman.Dispatch.on_assignee_change/4`, task row
  locked). Returns how many.
  """
  @spec cancel_reassigned(Task.t()) :: non_neg_integer()
  def cancel_reassigned(%Task{id: task_id, assignee_id: assignee_id}) do
    from(r in Run,
      where: r.task_id == ^task_id and r.status == :deferred and dependency_gated_sql(r.triggers)
    )
    |> other_agent(assignee_id)
    |> Runs.cancel_pending(:obsolete)
  end

  defp other_agent(query, nil), do: query
  defp other_agent(query, agent_id), do: where(query, [r], r.agent_id != ^agent_id)

  @doc """
  The `Helmsman.Tasks.TransitionSteps` step (decision 8): a task moved to
  `cancelled` or `verified` has its runs deferred by a dependency
  cancelled (`obsolete`).
  """
  @spec after_transition(Task.t(), TaskEvent.t(), Scope.t()) :: :ok
  def after_transition(%Task{id: task_id}, %TaskEvent{to_status: to}, _scope)
      when to in @closed do
    from(r in Run,
      where: r.task_id == ^task_id and r.status == :deferred and dependency_gated_sql(r.triggers)
    )
    |> Runs.cancel_pending(:obsolete)

    :ok
  end

  def after_transition(_task, _event, _scope), do: :ok

  ## Sweep

  @doc """
  The sweep (decision 9). Selects, before the limit, only the runs to act
  on now: `deferred`, on a task, waiting for dependencies, and whose task
  has no unsatisfied prerequisite (`Helmsman.Links.unsatisfied_dependency/1`)
  or is `cancelled` / `verified` or no longer assigned to the run's
  agent; by `(updated_at, id)`, #{@sweep_batch} at a time, at most
  #{@sweep_batches} batches. Each batch is handled workspace by workspace
  in a transaction (maintenance lock shared, graph lock): obsolete runs
  are cancelled, then the tasks are released (`release/1`, which checks
  again). Runs still blocked are never selected, so they cannot starve
  the others; no `updated_at` is touched to rotate. Returns how many runs
  were selected.
  """
  @spec sweep() :: non_neg_integer()
  def sweep, do: sweep_batches(nil, 0, 0)

  defp sweep_batches(_cursor, @sweep_batches, total), do: total

  defp sweep_batches(cursor, n, total) do
    rows = sweep_candidates(cursor)

    rows
    |> Enum.group_by(& &1.workspace_id)
    |> Enum.sort()
    |> Enum.each(fn {workspace_id, group} -> sweep_workspace(workspace_id, group) end)

    total = total + length(rows)

    if length(rows) < @sweep_batch,
      do: total,
      else: sweep_batches(List.last(rows), n + 1, total)
  end

  defp sweep_candidates(cursor) do
    actionable =
      dynamic(
        [run: r, task: t],
        not (^Links.unsatisfied_dependency(:task)) or t.status in ^@closed or
          fragment("? IS DISTINCT FROM ?", t.assignee_id, r.agent_id)
      )

    from(r in Run,
      as: :run,
      join: t in Task,
      as: :task,
      on: t.id == r.task_id,
      where: r.status == :deferred and dependency_gated_sql(r.triggers),
      where: ^actionable,
      order_by: [asc: r.updated_at, asc: r.id],
      limit: ^@sweep_batch,
      select: %{
        id: r.id,
        workspace_id: r.workspace_id,
        task_id: r.task_id,
        updated_at: r.updated_at
      }
    )
    |> after_cursor(cursor)
    |> Repo.all()
  end

  defp after_cursor(query, nil), do: query

  defp after_cursor(query, %{updated_at: updated_at, id: id}),
    do:
      where(
        query,
        [run: r],
        fragment(
          "(?, ?) > (?, ?)",
          r.updated_at,
          r.id,
          type(^updated_at, :utc_datetime_usec),
          ^id
        )
      )

  defp sweep_workspace(workspace_id, rows) do
    ids = Enum.map(rows, & &1.id)

    {:ok, :ok} =
      Tx.run(fn ->
        Locks.maint_shared!(workspace_id)
        :ok = Locks.graph!(workspace_id)

        from(r in Run,
          as: :run,
          where: r.id in ^ids and r.status == :deferred,
          where:
            exists(
              from(t in Task,
                where:
                  t.id == parent_as(:run).task_id and
                    (t.status in ^@closed or
                       fragment("? IS DISTINCT FROM ?", t.assignee_id, parent_as(:run).agent_id))
              )
            )
        )
        |> Runs.cancel_pending(:obsolete)

        {:ok, release(Enum.map(rows, & &1.task_id))}
      end)
  end
end
