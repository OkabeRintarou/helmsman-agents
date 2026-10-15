defmodule Helmsman.Squads.EpicStalledTest do
  # improve-squad-leader-orchestration 2.1: squad-orchestration 「Epic 停滞」
  # (decision 9), one row per exclusion.
  use Helmsman.DataCase, async: true

  import Helmsman.OrchestrationFixtures
  import Helmsman.ProjectsFixtures
  import Helmsman.RunsFixtures

  alias Helmsman.{Links, Repo, Squads, Tasks}
  alias Helmsman.Runs.Run
  alias Helmsman.Squads.EpicWatch
  alias Helmsman.Tasks.Task

  setup do
    ctx = orchestration_fixture()
    Repo.update_all(from(r in Run, where: r.status == :running), set: [status: :succeeded])
    ctx
  end

  defp set!(task, changes),
    do: Repo.update_all(from(t in Task, where: t.id == ^task.id), set: changes)

  defp snapshot(ctx), do: EpicWatch.snapshot(Repo.reload!(ctx.epic))
  defp stalled?(ctx), do: EpicWatch.stalled?(snapshot(ctx))
  defp idle(ctx), do: ctx |> snapshot() |> EpicWatch.idle() |> Enum.map(& &1.task.ident)

  # Only `task` left among the steps: the others are verified.
  defp only!(ctx, task) do
    for s <- [ctx.s1, ctx.s2, ctx.s3], s.id != task.id, do: set!(s, status: :verified)
  end

  test "idle steps and nothing running: stalled", ctx do
    assert stalled?(ctx)
    assert idle(ctx) == Enum.map([ctx.s1, ctx.s2, ctx.s3], & &1.ident)
  end

  test "a deferred step does not count; its stuck prerequisite does", ctx do
    only!(ctx, ctx.s2)
    s4 = task_fixture(ctx.alice_scope, ctx.project.key, %{title: "s4", epic: ctx.epic.ident})
    {:ok, _} = Tasks.update(ctx.alice_scope, s4.ident, %{assignee: "keel/fe", start: false})
    {:ok, _} = Links.add(ctx.alice_scope, s4.ident, ctx.s2.ident, "depends_on")
    run_fixture(ctx.fe, %{task_id: s4.id, status: :deferred})

    assert stalled?(ctx)
    assert idle(ctx) == [ctx.s2.ident]
  end

  @exclusions [
    {"the epic is new", &__MODULE__.epic_new/1},
    {"the epic waits for an answer", &__MODULE__.epic_question/1},
    {"the epic is blocked", &__MODULE__.epic_blocked/1},
    {"a step runs", &__MODULE__.step_running/1},
    {"the epic runs", &__MODULE__.epic_running/1},
    {"only a person's and an external agent's steps", &__MODULE__.people_only/1},
    {"only done and rejected steps", &__MODULE__.finished_only/1},
    {"only a step with a deferred run", &__MODULE__.deferred_only/1},
    {"the squad is disabled", &__MODULE__.squad_disabled/1}
  ]

  for {name, fun} <- @exclusions do
    @fun fun
    test "not stalled: #{name}", ctx do
      @fun.(ctx)
      refute stalled?(ctx)
    end
  end

  def epic_new(ctx), do: set!(ctx.epic, status: :new)
  def epic_question(ctx), do: set!(ctx.epic, open_question: true)

  def epic_blocked(ctx) do
    other = task_fixture(ctx.alice_scope, ctx.project.key)
    {:ok, _} = Links.add(ctx.alice_scope, ctx.epic.ident, other.ident, "depends_on")
  end

  def step_running(ctx), do: run_fixture(ctx.fe, %{task_id: ctx.s1.id, status: :running})

  def epic_running(ctx),
    do: run_fixture(ctx.lead, %{task_id: ctx.epic.id, status: :queued, squad_id: ctx.squad.id})

  def people_only(ctx) do
    bob = human_actor(ctx.workspace, ctx.bob)
    {:ok, ext} = Helmsman.Actors.identify(ctx.alice_scope, %{name: "claude-desktop"})
    set!(ctx.s1, assignee_id: bob.id)
    set!(ctx.s2, assignee_id: ext.id)
    set!(ctx.s3, status: :verified)
  end

  def finished_only(ctx) do
    set!(ctx.s1, status: :done)
    set!(ctx.s2, status: :rejected)
    set!(ctx.s3, status: :verified)
  end

  def deferred_only(ctx) do
    only!(ctx, ctx.s1)
    run_fixture(ctx.fe, %{task_id: ctx.s1.id, status: :deferred})
  end

  def squad_disabled(ctx), do: {:ok, _} = Squads.disable(ctx.alice_scope, "web-team")
end
