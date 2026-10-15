defmodule Helmsman.TaskSpecs.Dispatch do
  @moduledoc """
  The runs spec writes cause (`add-spec-workflow` decisions 10, 11, 13).

  `plan/3` says whom a write would trigger, from the task and spec as
  read; the write calls it once without locks (the guess) and again under
  the task and spec row locks (`Helmsman.Dispatch.Targets.with_locked/4`):
  the targets are locked before the task row, and a round whose targets
  changed is rolled back, before anything was written, and taken again
  (at most 3 rounds, then `busy`).

    * `{:request_reviews, reviewers}` — the reviewers that are agents
      (`spec_review`, a new trigger in the `reply` lane);
    * `{:submit_review, scope}` — the task's assignee when a person (not
      in a run) completes a request a run made, the task is `new` /
      `in_progress` and its assignee is an agent or a squad
      (`spec_reviewed`);
    * `{:decide, wake}` — the same assignee when `wake` is set
      (`spec_decided`).

  `wake/4` runs `spec_reviewed` / `spec_decided` for the task's current
  assignee: a squad's current leader as the squad, or a managed agent,
  inheriting the task's `assign` grant of the assignee (none →
  `skipped / unauthorized`), in the `work` lane, regardless of
  dependencies.
  """

  import Ecto.Query, warn: false

  alias Helmsman.Accounts.Scope
  alias Helmsman.Actors.Actor
  alias Helmsman.Agents.AgentProfile
  alias Helmsman.Repo
  alias Helmsman.Runs
  alias Helmsman.Runs.{Origin, Outcome, TaskGrant}
  alias Helmsman.Squads
  alias Helmsman.Squads.Dispatch, as: SquadDispatch
  alias Helmsman.Tasks.Task
  alias Helmsman.TaskSpecs.{ReviewRequest, Spec}

  @open [:new, :in_progress]

  @type dispatch :: %{
          target: String.t(),
          squad: String.t() | nil,
          result: Outcome.result(),
          reason: Outcome.reason() | nil,
          run_id: pos_integer() | nil
        }

  @type op ::
          {:request_reviews, [String.t()]}
          | {:submit_review, Scope.t()}
          | {:decide, boolean()}
          | {:coordinate, nil}

  @doc """
  The actor IDs to lock for `op`: those it would trigger, and the task's
  assignee when it is a squad (its leader and finalize mode decide who
  coordinates, so the squad's rows are locked too; code-review-1 P1-1).
  """
  @spec plan(op(), Task.t() | nil, Spec.t() | nil) :: [pos_integer()]
  def plan(_op, nil, _spec), do: []

  def plan(op, task, spec), do: Enum.uniq(triggered(op, task, spec) ++ squad_assignee(task))

  defp squad_assignee(%Task{assignee_id: id}) when is_integer(id),
    do: Repo.all(from(a in Actor, where: a.id == ^id and a.kind == :squad, select: a.id))

  defp squad_assignee(_task), do: []

  # The reviewers' names as they resolve now: the agents among them.
  defp triggered({:request_reviews, names}, task, _spec) do
    Repo.all(
      from(a in Actor,
        where: a.workspace_id == ^task.workspace_id and a.name in ^names and a.kind == :agent,
        select: a.id
      )
    )
  end

  defp triggered(
         {:submit_review, %Scope{actor: %Actor{kind: :human} = actor, run: nil}},
         task,
         spec
       ) do
    if spec && wakes?(task) && run_request?(spec, actor.id), do: [task.assignee_id], else: []
  end

  defp triggered({:decide, true}, task, _spec),
    do: if(wakes?(task), do: [task.assignee_id], else: [])

  defp triggered(_op, _task, _spec), do: []

  @doc "Whether a person's review of `spec` wakes the task's assignee."
  @spec wakes_on_review?(Scope.t(), Task.t(), Spec.t()) :: boolean()
  def wakes_on_review?(scope, task, spec),
    do: triggered({:submit_review, scope}, task, spec) != []

  defp wakes?(%Task{status: status, assignee_id: id}) when status in @open and is_integer(id),
    do: Repo.exists?(from(a in Actor, where: a.id == ^id and a.kind in [:agent, :squad]))

  defp wakes?(_task), do: false

  # A `requested` request of `reviewer_id` on the latest version that a
  # run made.
  defp run_request?(%Spec{id: spec_id, latest_version: latest}, reviewer_id) do
    Repo.exists?(
      from(r in ReviewRequest,
        join: v in assoc(r, :version),
        where:
          r.spec_id == ^spec_id and r.reviewer_id == ^reviewer_id and r.status == :requested and
            v.number == ^latest and not is_nil(r.request_run_id)
      )
    )
  end

  @doc """
  The `spec_review` run of a reviewer for request `request` on `version`,
  from `scope` (a person or a credential, not a run); nil when the
  reviewer is not a managed agent. The reviewer's rows are locked.
  """
  @spec review(Scope.t(), Task.t(), Actor.t(), %{
          request: pos_integer(),
          version: pos_integer(),
          note: String.t() | nil
        }) :: dispatch() | nil
  def review(%Scope{} = scope, %Task{} = task, %Actor{kind: :agent} = reviewer, request) do
    case Repo.one(from(p in AgentProfile, where: p.actor_id == ^reviewer.id)) do
      nil ->
        nil

      profile ->
        trigger = %{
          kind: :spec_review,
          instructions: request.note,
          extra: %{"spec_request" => request.request, "spec_version" => request.version}
        }

        target = %{agent: reviewer, profile: profile, task: task, lane: :reply}
        {:ok, outcome} = Runs.enqueue(Origin.from_scope(scope), target, trigger)
        view(outcome)
    end
  end

  def review(_scope, _task, _reviewer, _request), do: nil

  @doc """
  Wakes the task's assignee with `kind` (`:spec_reviewed` /
  `:spec_decided`) and the trigger fields `extra`; see the module
  documentation. nil when the assignee is not a managed agent or a squad.
  """
  @spec wake(Scope.t(), Task.t(), :spec_reviewed | :spec_decided, map()) :: dispatch() | nil
  def wake(%Scope{} = scope, %Task{assignee_id: id} = task, kind, extra) when is_integer(id) do
    trigger = %{kind: kind, instructions: nil, extra: extra}

    case Repo.get!(Actor, id) do
      %Actor{kind: :squad} = squad_actor ->
        loaded = Squads.load(Squads.by_actor_id(squad_actor.id))

        case grant(task, squad_actor) do
          nil ->
            view(SquadDispatch.skipped(loaded, kind, :unauthorized, [loaded.leader.name]))

          grant ->
            origin = inherit(scope, grant, loaded.leader)
            view(SquadDispatch.enqueue(origin, loaded, task, trigger, lane: :work))
        end

      %Actor{kind: :agent} = agent ->
        wake_agent(scope, task, agent, trigger)

      _other ->
        nil
    end
  end

  def wake(_scope, _task, _kind, _extra), do: nil

  defp wake_agent(scope, task, agent, trigger) do
    case Repo.one(from(p in AgentProfile, where: p.actor_id == ^agent.id)) do
      nil ->
        nil

      profile ->
        case grant(task, agent) do
          nil ->
            view(Outcome.skipped(agent, trigger.kind, :unauthorized))

          grant ->
            target = %{agent: agent, profile: profile, task: task, lane: :work}
            {:ok, outcome} = Runs.enqueue(inherit(scope, grant, agent), target, trigger)
            view(outcome)
        end
    end
  end

  defp grant(task, actor),
    do: Repo.get_by(TaskGrant, task_id: task.id, agent_id: actor.id, kind: :assign)

  defp inherit(scope, grant, agent) do
    %Origin{
      by_actor_id: scope.actor.id,
      initiator_user_id: grant.root_initiator_user_id,
      chain: Enum.reject(grant.causal_agent_ids, &(&1 == agent.id))
    }
  end

  @doc "The dispatch view of an outcome (界面契约)."
  @spec view(Outcome.t()) :: dispatch()
  def view(%Outcome{} = outcome) do
    %{
      target: outcome.agent,
      squad: outcome.squad,
      result: outcome.result,
      reason: outcome.reason,
      run_id: outcome.run_id
    }
  end
end
