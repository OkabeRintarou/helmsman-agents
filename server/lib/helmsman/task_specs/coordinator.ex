defmodule Helmsman.TaskSpecs.Coordinator do
  @moduledoc """
  Who coordinates a task's spec, and how it is finalized
  (`add-spec-workflow` decision 7).

  `resolve/2`:

    * `:human` — the scope is a person (not in a run);
    * `{:leader, squad}` — a run as a squad (`runs.squad_id`) whose squad
      is the task's assignee and whose agent still leads it;
    * `{:assignee_agent, agent}` — a run of, or an `hm_` credential of,
      the agent that is the task's assignee (in a run, only on this task);
    * `:none` — anyone else, e.g. a member's delegated run on a squad's
      task.

  `mode/1`: the squad's `spec_finalize` when the assignee is a squad that
  set one, else the project's. `:leader` only lets `{:leader, _}`
  finalize directly.
  """

  import Ecto.Query, warn: false

  alias Helmsman.Accounts.Scope
  alias Helmsman.Actors.Actor
  alias Helmsman.Projects.Project
  alias Helmsman.Repo
  alias Helmsman.Runs.Run
  alias Helmsman.Squads.Squad
  alias Helmsman.Tasks.Task

  @type t :: :human | {:leader, Squad.t()} | {:assignee_agent, Actor.t()} | :none

  @doc "See the module documentation."
  @spec resolve(Scope.t(), Task.t()) :: t()
  def resolve(%Scope{actor: %Actor{kind: :human}, run: nil}, %Task{}), do: :human

  def resolve(%Scope{run: %Run{squad_id: squad_id} = run}, %Task{} = task)
      when is_integer(squad_id) do
    squad = Repo.get(Squad, squad_id)

    if ((run.task_id == task.id and squad) && squad.actor_id == task.assignee_id) and
         squad.leader_agent_id == run.agent_id,
       do: {:leader, squad},
       else: :none
  end

  def resolve(%Scope{run: %Run{} = run, actor: actor}, %Task{} = task) do
    if run.task_id == task.id and run.agent_id == task.assignee_id,
      do: {:assignee_agent, actor},
      else: :none
  end

  def resolve(%Scope{actor: %Actor{kind: :agent, id: id} = actor}, %Task{assignee_id: id}),
    do: {:assignee_agent, actor}

  def resolve(%Scope{}, %Task{}), do: :none

  @doc "The finalize mode of a task's spec; see the module documentation."
  @spec mode(Task.t()) :: :approval | :leader
  def mode(%Task{assignee_id: assignee_id, project_id: project_id}) do
    squad_mode =
      assignee_id &&
        Repo.one(from(s in Squad, where: s.actor_id == ^assignee_id, select: s.spec_finalize))

    squad_mode ||
      Repo.one!(from(p in Project, where: p.id == ^project_id, select: p.spec_finalize))
  end

  @doc """
  The description of who may coordinate the task's spec, for
  `not_coordinator`: the assignee's name and kind (nil: no assignee).
  """
  @spec who(Task.t()) :: %{task: String.t(), assignee: String.t() | nil, kind: atom() | nil}
  def who(%Task{ident: ident, assignee_id: nil}), do: %{task: ident, assignee: nil, kind: nil}

  def who(%Task{ident: ident, assignee_id: id}) do
    %Actor{name: name, kind: kind} = Repo.get!(Actor, id)
    %{task: ident, assignee: name, kind: kind}
  end
end
