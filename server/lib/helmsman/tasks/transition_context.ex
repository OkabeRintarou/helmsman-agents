defmodule Helmsman.Tasks.TransitionContext do
  @moduledoc """
  Collects the context `Helmsman.Tasks.StateMachine.check/3` needs, inside
  the transition's transaction with the task row locked.

  `blockers` (the unsatisfied prerequisites, `Helmsman.Links.blockers/1`)
  is read for a move from `new` to `in_progress` only, `replaced_by`
  (`Helmsman.Links.replaced_by/1`) for a move from `cancelled` to `new`
  only; the transition holds the graph lock, so both are stable until it
  commits. The automatic claim of a run (`Helmsman.Tasks.auto_claim_for_run/1`)
  builds no context: it does not check dependencies. `active_run` is the earliest other run of the task that is
  claimed, running or cancelling (`Helmsman.Runs.active_on_task/2`,
  excluding `scope.run`, the run making the transition), read for a move
  to `verified` only. The self-verification fields follow designs/05 §5: only the
  acting identity itself counts as the assignee, not other identities of
  the same user.
  """

  import Ecto.Query, warn: false

  alias Helmsman.Accounts.Scope
  alias Helmsman.Actors.Actor
  alias Helmsman.Links
  alias Helmsman.Repo
  alias Helmsman.Runs
  alias Helmsman.Tasks.{Evidence, StateMachine, Task, TaskEvent}

  @doc "Builds the check context for moving `task` to `to` as `scope`."
  @spec build(Task.t(), Scope.t(), Task.status(), Evidence.t()) :: StateMachine.ctx()
  def build(%Task{} = task, %Scope{actor: %Actor{} = actor} = scope, to, evidence) do
    self_verify? =
      to == :verified and not is_nil(task.assignee_id) and actor.id == task.assignee_id

    %{
      blockers: blockers(task, to),
      replaced_by: replaced_by(task, to),
      active_run: if(to == :verified, do: Runs.active_on_task(task.id, run_id(scope))),
      self_verify?: self_verify?,
      has_passing_tests?: to == :verified and passing_tests?(task, evidence),
      assignee_name: if(self_verify?, do: actor.name, else: assignee_name(task))
    }
  end

  defp blockers(%Task{status: :new, id: id}, :in_progress), do: Links.blockers(id)
  defp blockers(_task, _to), do: []

  defp replaced_by(%Task{status: :cancelled, id: id}, :new), do: Links.replaced_by(id)
  defp replaced_by(_task, _to), do: []

  defp run_id(%Scope{run: %{id: id}}), do: id
  defp run_id(_scope), do: nil

  # This transition's tests, or else those of the latest transition to
  # `done`: an older passing result does not count once the task was done
  # again without one.
  defp passing_tests?(_task, %{tests: %{"passed" => true}}), do: true

  defp passing_tests?(%Task{id: task_id}, _evidence) do
    query =
      from(e in TaskEvent,
        where: e.task_id == ^task_id and e.to_status == :done,
        order_by: [desc: e.inserted_at, desc: e.id],
        limit: 1,
        select: fragment("(?->'passed') = 'true'::jsonb", e.tests)
      )

    Repo.one(query) == true
  end

  defp assignee_name(%Task{assignee_id: nil}), do: nil
  defp assignee_name(%Task{assignee: %Actor{name: name}}), do: name

  defp assignee_name(%Task{assignee_id: id}),
    do: Repo.one(from(a in Actor, where: a.id == ^id, select: a.name))
end
