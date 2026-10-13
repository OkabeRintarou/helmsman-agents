defmodule Helmsman.Runs.Stop do
  @moduledoc """
  Stopping runs (designs/13 §8, `add-run-lifecycle` decisions 15, 26).

  A pending run (`deferred`, `queued`) is `cancelled` at once. A claimed or
  running run becomes `cancelling` and its daemon is told
  (`{:cancel_run, id}` on `daemon:<id>` after the commit, pushed as
  `cancel`); it becomes `cancelled` when the daemon reports its end
  (`Helmsman.Runs.Lifecycle.finish/2`) or when the daemon has been offline
  for the grace period (`Helmsman.Runs.Workers.Sweep`).
  """

  import Ecto.Query, warn: false

  alias Helmsman.Accounts.Scope
  alias Helmsman.Actors.Actor
  alias Helmsman.Events
  alias Helmsman.Policy
  alias Helmsman.Repo
  alias Helmsman.Runs
  alias Helmsman.Runs.{Lifecycle, Run}
  alias Helmsman.Workspaces

  @doc """
  Stops the run `run_id` of the scope's workspace (`:cancel_run`: admins,
  or members who are its authorization source or own its agent; never a
  run token). `cancelling` already: unchanged. Ended:
  `{:error, :already_finished}`. Records who asked.
  """
  @spec cancel(Scope.t(), integer()) ::
          {:ok, Runs.summary()} | {:error, :forbidden | :not_found | :already_finished}
  def cancel(%Scope{} = scope, run_id) when is_integer(run_id) do
    Workspaces.write_transaction(scope, :view_runs, nil, fn scope ->
      with {:ok, run} <- lock_run(scope, run_id),
           :ok <- Policy.authorize(scope, :cancel_run, policy_resource(run)) do
        cancel_locked(run, scope)
      end
    end)
  end

  @doc false
  # The run's resource for `:cancel_run` / `:retry_run`.
  @spec policy_resource(Run.t()) :: %{initiator_id: pos_integer(), agent_owner_id: pos_integer()}
  def policy_resource(%Run{} = run) do
    owner_id = Repo.one!(from(a in Actor, where: a.id == ^run.agent_id, select: a.owner_id))
    %{initiator_id: run.root_initiator_user_id, agent_owner_id: owner_id}
  end

  defp lock_run(scope, run_id) do
    query =
      from(r in Run,
        where: r.workspace_id == ^scope.workspace.id and r.id == ^run_id,
        lock: "FOR UPDATE"
      )

    case Repo.one(query) do
      nil -> {:error, :not_found}
      run -> {:ok, run}
    end
  end

  defp cancel_locked(run, scope) do
    case stop_locked(run, actor_id(scope)) do
      {:ok, run} -> {:ok, Runs.summary(run)}
      error -> error
    end
  end

  @doc """
  Stops the run, locked `FOR UPDATE` by the caller, without any
  authorization (the caller decided it may: `cancel/2`, or a person
  stopping the turn of their own creation conversation,
  `add-agent-conversation` decision 10): pending → `cancelled`, `claimed`
  or `running` → `cancelling` (its daemon told after the commit),
  `cancelling` unchanged; ended → `{:error, :already_finished}`.
  `requested_by` is the actor recorded as asking (nil: none).
  """
  @spec stop_locked(Run.t(), pos_integer() | nil) ::
          {:ok, Run.t()} | {:error, :already_finished}
  def stop_locked(%Run{status: status} = run, requested_by)
      when status in [:deferred, :queued],
      do: {:ok, Lifecycle.end!(run, :cancelled, cancel_requested_by_id: requested_by)}

  def stop_locked(%Run{status: status} = run, requested_by) when status in [:claimed, :running] do
    run = Lifecycle.update!(run, status: :cancelling, cancel_requested_by_id: requested_by)
    push_cancel(run)
    {:ok, run}
  end

  def stop_locked(%Run{status: :cancelling} = run, _requested_by), do: {:ok, run}
  def stop_locked(_run, _requested_by), do: {:error, :already_finished}

  defp actor_id(%Scope{actor: %Actor{id: id}}), do: id
  defp actor_id(_scope), do: nil

  @doc """
  Moves the `claimed` and `running` runs among `queryable` to `cancelling`
  in the caller's transaction (an agent disabled or archived, its owner
  removed: decision 15), with no failure reason and no requester, and
  tells their daemons after the commit. Call it after
  `Helmsman.Runs.cancel_pending/2`. Returns how many.
  """
  @spec stop_active(Ecto.Queryable.t()) :: non_neg_integer()
  def stop_active(queryable) do
    ids =
      Repo.all(
        from(r in queryable,
          where: r.status in [:claimed, :running],
          order_by: r.id,
          lock: "FOR UPDATE",
          select: r.id
        )
      )

    stop(ids, [])
  end

  @doc """
  Stops, in the caller's transaction, the runs of the workspace whose
  authorization source is `user_id`, who leaves or is removed from it
  (decision 26), whoever owns the agent: pending ones `cancelled`, claimed
  and running ones `cancelling` (their daemons told after the commit),
  both with the reason `unauthorized`. `cancelling` and ended runs are left
  alone. Call it after the membership rows are locked and before the runs
  of the user's own agents are handled, so `unauthorized` wins.
  """
  @spec cancel_for_initiator(pos_integer(), pos_integer()) :: non_neg_integer()
  def cancel_for_initiator(workspace_id, user_id) do
    rows =
      Repo.all(
        from(r in Run,
          where:
            r.workspace_id == ^workspace_id and r.root_initiator_user_id == ^user_id and
              r.status in [:deferred, :queued, :claimed, :running],
          order_by: r.id,
          lock: "FOR UPDATE",
          select: {r.id, r.status}
        )
      )

    {pending, active} =
      Enum.split_with(rows, fn {_id, status} -> status in [:deferred, :queued] end)

    now = DateTime.utc_now()

    {count, runs} =
      Repo.update_all(
        from(r in Run, where: r.id in ^Enum.map(pending, &elem(&1, 0)), select: r),
        set: [
          status: :cancelled,
          failure_reason: :unauthorized,
          finished_at: now,
          updated_at: now
        ]
      )

    Enum.each(runs, &Runs.notify_run/1)
    Runs.after_ended(runs)
    count + stop(Enum.map(active, &elem(&1, 0)), failure_reason: :unauthorized)
  end

  defp stop([], _changes), do: 0

  defp stop(ids, changes) do
    {count, runs} =
      Repo.update_all(
        from(r in Run, where: r.id in ^ids, select: r),
        set: [status: :cancelling, updated_at: DateTime.utc_now()] ++ changes
      )

    Enum.each(runs, fn run ->
      Runs.notify_run(run)
      push_cancel(run)
    end)

    count
  end

  defp push_cancel(%Run{daemon_id: nil}), do: :ok

  defp push_cancel(%Run{id: id, daemon_id: daemon_id}),
    do: Events.after_commit(Events.topic(:daemon, daemon_id), {:cancel_run, id})
end
