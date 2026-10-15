defmodule Helmsman.Dispatch.LeaderSquad do
  @moduledoc """
  A mention or a manual run of a squad's leader as the squad
  (`improve-squad-leader-orchestration` decision 14).

  When the managed agent A is mentioned on, or started by hand on, the
  task T, and A is the current leader of a squad S that is not disabled,
  with T assigned to S or T's epic assigned to S (T's assignee first), the
  run is A's as S (`squad_id` = S, the lane unchanged) — provided whoever
  triggers it may trigger S (its leader and all its managed members).
  Otherwise it is A's own run; a refusal is recorded on the trigger
  (`"squad_refused"`: the members in the way, `"refused_squad"`,
  `"squad_owner"`: the task S owns) for the prompt. Squads A leads that T
  does not belong to are never chosen. Assignments to A itself are not
  upgraded: only mentions and manual runs call this module.

  The squad's rows must be locked before the task row: callers take the
  candidates of `guess/2` first and compare `candidate/2`, read under the
  task lock, with them (`Helmsman.Dispatch.Targets`, `Dispatch.run_agent/4`).
  For a step, the epic's owner is guarded by the workspace graph lock
  (reassigning or attaching a task takes it, `Helmsman.Tasks.update/4`),
  taken before every other lock: callers take it when `on_epic?/2` says so,
  and when `graph_needed?/1`, under the task lock, says so but they did not
  they take the round again with it.
  """

  import Ecto.Query, warn: false

  alias Helmsman.Actors.Actor
  alias Helmsman.Repo
  alias Helmsman.Runs
  alias Helmsman.Runs.{Origin, Outcome}
  alias Helmsman.Squads
  alias Helmsman.Squads.Dispatch, as: SquadDispatch
  alias Helmsman.Squads.Squad
  alias Helmsman.Tasks.Task

  @doc """
  The identities that may own the task `ident` for its leaders, read
  without locking: its assignee and its epic's assignee.
  """
  @spec guess(pos_integer(), String.t() | nil) :: [pos_integer()]
  def guess(_workspace_id, ident) when ident in [nil, ""], do: []

  def guess(workspace_id, ident) do
    Repo.one(
      from(t in Task,
        left_join: e in Task,
        on: e.id == t.epic_id,
        where: t.workspace_id == ^workspace_id and t.ident == ^ident,
        select: [t.assignee_id, e.assignee_id]
      )
    )
    |> List.wrap()
    |> Enum.reject(&is_nil/1)
  end

  @doc "Whether the task `ident` is a step, read without locking."
  @spec on_epic?(pos_integer(), String.t() | nil) :: boolean()
  def on_epic?(_workspace_id, ident) when ident in [nil, ""], do: false

  def on_epic?(workspace_id, ident) do
    Repo.exists?(
      from(t in Task,
        where: t.workspace_id == ^workspace_id and t.ident == ^ident and not is_nil(t.epic_id)
      )
    )
  end

  @doc """
  Whether `candidate/2` on `task`, locked, needs the workspace graph lock
  held: the task is a step.
  """
  @spec graph_needed?(Task.t() | nil) :: boolean()
  def graph_needed?(nil), do: false
  def graph_needed?(%Task{epic_id: epic_id}), do: not is_nil(epic_id)

  @doc """
  The identity of the squad `agent_id` leads that owns `task` (see the
  module documentation), or nil. Read under the task lock and, when
  `graph_needed?/1`, the workspace graph lock.
  """
  @spec candidate(Task.t() | nil, pos_integer()) :: pos_integer() | nil
  def candidate(nil, _agent_id), do: nil

  def candidate(%Task{} = task, agent_id) do
    owners = [task.assignee_id, epic_assignee(task)] |> Enum.reject(&is_nil/1) |> Enum.uniq()

    led =
      if owners == [] do
        []
      else
        Repo.all(
          from(s in Squad,
            join: a in Actor,
            on: a.id == s.actor_id,
            where:
              s.actor_id in ^owners and s.leader_agent_id == ^agent_id and is_nil(a.disabled_at),
            select: s.actor_id
          )
        )
      end

    test_hook(:leader_candidate)
    Enum.find(owners, &(&1 in led))
  end

  defp epic_assignee(%Task{epic_id: nil}), do: nil

  defp epic_assignee(%Task{epic_id: epic_id}),
    do: Repo.one(from(t in Task, where: t.id == ^epic_id, select: t.assignee_id))

  @doc """
  Enqueues `trigger` (as `Helmsman.Runs.enqueue/3` takes it) for the
  managed `agent` on `task` in `lane`: as the squad whose identity is
  `squad_actor_id` when `origin` may trigger it, else as the agent alone
  with the refusal on the trigger. A nil squad: the agent alone.
  """
  @spec enqueue(Origin.t(), map(), pos_integer() | nil, Runs.trigger()) :: Outcome.t()
  def enqueue(%Origin{} = origin, %{agent: agent, task: task} = target, squad_actor_id, trigger) do
    loaded = squad_actor_id && Squads.load(Squads.by_actor_id(squad_actor_id))

    case loaded && SquadDispatch.check(origin, loaded, trigger.kind) do
      nil ->
        alone(origin, target, trigger)

      :ok ->
        trigger = put_extra(trigger, %{"as_leader" => true})
        SquadDispatch.enqueue(origin, loaded, task, trigger, check: false, lane: target.lane)

      {:skip, %Outcome{reason: :unauthorized, refused: refused}} ->
        refusal = %{
          "squad_refused" => refused || [agent.name],
          "refused_squad" => loaded.actor.name,
          "squad_owner" => owner_ident(task, squad_actor_id)
        }

        alone(origin, target, put_extra(trigger, refusal))

      {:skip, _other} ->
        alone(origin, target, trigger)
    end
  end

  defp alone(origin, target, trigger) do
    {:ok, outcome} = Runs.enqueue(origin, target, trigger)
    outcome
  end

  defp put_extra(trigger, extra), do: Map.update(trigger, :extra, extra, &Map.merge(&1, extra))

  # The task the squad owns: the task itself, or its epic.
  defp owner_ident(%Task{assignee_id: id, ident: ident}, id), do: ident

  defp owner_ident(%Task{epic_id: epic_id}, _squad_actor_id),
    do: Repo.one(from(t in Task, where: t.id == ^epic_id, select: t.ident))

  # Concurrency tests change rows between the candidate and the enqueue:
  # compiled in the test environment only.
  if Mix.env() == :test do
    defp test_hook(point) do
      case Process.get(:helmsman_test_hook) do
        hook when is_function(hook, 1) -> hook.(point)
        _ -> :ok
      end
    end
  else
    defp test_hook(_point), do: :ok
  end
end
