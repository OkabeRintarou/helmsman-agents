defmodule Helmsman.Tasks.TransitionContext do
  @moduledoc """
  Collects the context `Helmsman.Tasks.StateMachine.check/3` needs, inside
  the transition's transaction with the task row locked.

  Later changes fill in `blockers` (task links), `replaced_by` (task links)
  and `active_run` (run dispatch; excluding `scope.run`, the run making the
  transition). The self-verification fields follow designs/05 §5: only the
  acting identity itself counts as the assignee, not other identities of
  the same user.
  """

  import Ecto.Query, warn: false

  alias Helmsman.Accounts.Scope
  alias Helmsman.Actors.Actor
  alias Helmsman.Repo
  alias Helmsman.Tasks.{Evidence, StateMachine, Task, TaskEvent}

  @doc "Builds the check context for moving `task` to `to` as `scope`."
  @spec build(Task.t(), Scope.t(), Task.status(), Evidence.t()) :: StateMachine.ctx()
  def build(%Task{} = task, %Scope{actor: %Actor{} = actor}, to, evidence) do
    self_verify? =
      to == :verified and not is_nil(task.assignee_id) and actor.id == task.assignee_id

    %{
      blockers: [],
      replaced_by: [],
      active_run: nil,
      self_verify?: self_verify?,
      has_passing_tests?: to == :verified and passing_tests?(task, evidence),
      assignee_name: if(self_verify?, do: actor.name, else: assignee_name(task))
    }
  end

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
