defmodule Helmsman.Squads.StartTask do
  @moduledoc """
  `start_task(task_id, instructions)` (`improve-squad-leader-orchestration`
  decision 5): an orchestrating run starts the assignee of a task of its
  scope, with an `assign` trigger marked as orchestrated.

  In one write transaction: maintenance lock and membership row, the
  workspace graph lock (an `assign` waits for dependencies, decided under
  it), then `Helmsman.Dispatch.Targets.with_locked/4` — the guess is the
  run's squad and the task's current assignee; their identity rows, the
  squad rows and profiles are locked, then the task row, and the assignee
  is read again: a different one rolls the round back (at most 3 rounds,
  then `busy`). Then `Helmsman.Squads.Orchestration.check/3`, the
  assignee rules (a managed agent member: `no_assignee`,
  `person_assignee`, `not_managed`, `not_member`), `task_closed`, and
  `already` when the assignee has a pending or active run on the task.
  Otherwise the trigger goes through `Helmsman.Runs.enqueue/3` with the
  run as its authorization source and chain (an agent-caused new trigger);
  an `assign` grant of the assignee is recorded when the task has none and
  the trigger was not refused for its source; a system note records the
  start and its outcome. Not dispatched is a result: the transaction
  commits.
  """

  import Ecto.Query, warn: false

  alias Helmsman.Accounts.Scope
  alias Helmsman.Actors.Actor
  alias Helmsman.Agents.AgentProfile
  alias Helmsman.Dispatch.Targets
  alias Helmsman.{Locks, Policy, Repo, Runs, Workspaces}
  alias Helmsman.Runs.{Origin, Run, TaskGrant}
  alias Helmsman.Squads.{Orchestration, Squad}
  alias Helmsman.Tasks
  alias Helmsman.Tasks.{Ident, Task}

  @max_instructions_bytes 8192
  @open [:new, :in_progress]
  @refused [:unauthorized, :loop_detected, :chain_too_long]

  @type result :: %{
          result: :queued | :merged | :deferred | :skipped | :already,
          reason: atom() | nil,
          assignee: String.t(),
          blocked_by: [String.t()] | nil,
          run: Runs.summary() | nil
        }

  @doc "See the module documentation."
  @spec start_task(Scope.t(), String.t(), term()) :: {:ok, result()} | {:error, term()}
  def start_task(%Scope{} = scope, ident, instructions) when is_binary(ident) do
    with :ok <- coarse(scope),
         {:ok, instructions} <- normalize(instructions),
         {:ok, ident, _key, _seq} <- Ident.parse(ident) do
      Workspaces.write_transaction(scope, :update_task, nil, &locked(&1, ident, instructions))
    end
  end

  # Only runs with the capability get here (others: `forbidden`).
  defp coarse(scope) do
    if Orchestration.orchestrating?(scope),
      do: Policy.authorize(scope, :orchestrate_task, %{covered: true, root?: false}),
      else: {:error, :forbidden}
  end

  defp normalize(nil), do: {:ok, nil}

  defp normalize(text) when is_binary(text) do
    case String.trim(text) do
      "" ->
        {:ok, nil}

      text when byte_size(text) > @max_instructions_bytes ->
        {:error, {:invalid_instructions, :too_long}}

      text ->
        {:ok, text}
    end
  end

  defp normalize(_other), do: {:error, {:invalid_instructions, :not_a_string}}

  defp locked(scope, ident, instructions) do
    workspace_id = scope.workspace.id
    Locks.graph!(workspace_id)

    squad_actor_id =
      Repo.one!(from(s in Squad, where: s.id == ^scope.run.squad_id, select: s.actor_id))

    guess = fn -> [squad_actor_id | managed(assignee_of(workspace_id, ident))] end
    lock = fn -> Tasks.lock(scope, ident) end
    targets = fn task -> {[squad_actor_id | managed(task.assignee_id)], nil} end

    with {:ok, task, nil} <- Targets.with_locked(workspace_id, guess, lock, targets),
         {:ok, ctx} <- Orchestration.check(scope, task, :start),
         :ok <- open(task),
         {:ok, agent, profile} <- assignee(ctx, task) do
      result =
        case active_run(task, agent) do
          %Run{} = run ->
            %{
              result: :already,
              reason: nil,
              assignee: agent.name,
              blocked_by: nil,
              run: Runs.summary(run)
            }

          nil ->
            start(scope, ctx, task, {agent, profile}, instructions)
        end

      {:ok, result}
    end
    |> emit()
  end

  defp emit(result) do
    Orchestration.emit(:start, result)
    result
  end

  defp assignee_of(workspace_id, ident) do
    Repo.one(
      from(t in Task,
        where: t.workspace_id == ^workspace_id and t.ident == ^ident,
        select: t.assignee_id
      )
    )
  end

  # Only agents are dispatch targets (a person assignee is refused later).
  defp managed(nil), do: []

  defp managed(id),
    do: Repo.all(from(a in Actor, where: a.id == ^id and a.kind == :agent, select: a.id))

  defp open(%Task{status: status}) when status in @open, do: :ok
  defp open(_task), do: {:error, :task_closed}

  defp assignee(_ctx, %Task{assignee_id: nil, ident: ident}),
    do: {:error, {:orchestration, :no_assignee, ident}}

  defp assignee(ctx, %Task{assignee_id: id, ident: ident}) do
    actor = Repo.get!(Actor, id)
    profile = Repo.one(from(p in AgentProfile, where: p.actor_id == ^id))

    cond do
      actor.kind == :human ->
        {:error, {:orchestration, :person_assignee, ident, actor.name}}

      id not in Orchestration.member_ids(ctx.squad) ->
        {:error, {:orchestration, :not_member, actor.name, ctx.squad_actor.name}}

      actor.kind != :agent or is_nil(profile) ->
        {:error, {:orchestration, :not_managed, ident, actor.name}}

      true ->
        {:ok, actor, profile}
    end
  end

  defp active_run(task, agent) do
    statuses = Run.pending_statuses() ++ Run.active_statuses()

    Repo.one(
      from(r in Run,
        where: r.task_id == ^task.id and r.agent_id == ^agent.id and r.status in ^statuses,
        order_by: [asc: r.id],
        limit: 1
      )
    )
  end

  defp start(scope, ctx, task, {agent, profile}, instructions) do
    origin = Origin.from_scope(scope)

    trigger = %{
      kind: :assign,
      instructions: instructions,
      extra: %{"orchestrated" => true, "orchestrator_run_id" => scope.run.id}
    }

    target = %{agent: agent, profile: profile, task: task, lane: :work}
    {:ok, outcome} = Runs.enqueue(origin, target, trigger)

    if outcome.result != :skipped or outcome.reason not in @refused,
      do: grant(task, agent, origin)

    what = "started #{agent.name} on #{task.ident}." <> Orchestration.quote(instructions)
    Orchestration.audit!(ctx, Repo.get!(Task, task.id), what, [outcome])

    %{
      result: outcome.result,
      reason: outcome.reason,
      assignee: agent.name,
      blocked_by: outcome.blocked_by,
      run: outcome.run_id && Runs.summary(Repo.get!(Run, outcome.run_id))
    }
  end

  # The task's `assign` grant of its assignee, so that a later reopen or
  # resubmit inherits it; one recorded by a person is kept as it is.
  defp grant(task, agent, %Origin{} = origin) do
    exists? =
      Repo.exists?(
        from(g in TaskGrant,
          where: g.task_id == ^task.id and g.agent_id == ^agent.id and g.kind == :assign
        )
      )

    unless exists? do
      Repo.insert!(%TaskGrant{
        workspace_id: task.workspace_id,
        task_id: task.id,
        agent_id: agent.id,
        kind: :assign,
        root_initiator_user_id: origin.initiator_user_id,
        causal_agent_ids: Enum.uniq(origin.chain ++ [agent.id]),
        granted_by_id: origin.by_actor_id,
        inserted_at: DateTime.utc_now()
      })
    end

    :ok
  end
end
