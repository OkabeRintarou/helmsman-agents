defmodule Helmsman.Tasks.EpicStepStatesTest do
  # improve-squad-leader-orchestration 2.1: task-epics 「Epic 的读取」 —
  # what each step waits for (decision 13).
  use Helmsman.DataCase, async: true

  import Helmsman.OrchestrationFixtures
  import Helmsman.ProjectsFixtures
  import Helmsman.RunsFixtures

  alias Helmsman.{Links, QueryCount, Repo, Tasks}
  alias Helmsman.Tasks.{Epics, Task}

  setup do
    orchestration_fixture()
  end

  defp set!(task, changes),
    do: Repo.update_all(from(t in Task, where: t.id == ^task.id), set: changes)

  defp step(ctx, title, attrs) do
    {:ok, task} =
      Tasks.create(
        ctx.lead_scope,
        ctx.project.key,
        Map.merge(%{title: title, epic: ctx.epic.ident, start: false}, attrs)
      )

    drop_queued()
    task
  end

  defp states(ctx), do: ctx.epic |> Epics.step_states() |> Map.new(&{&1.task.ident, &1})

  test "the ACC-10 example", ctx do
    # s1: verified without a repository or run → nothing; s2: keel/review, no
    # run → start; s3: unassigned → assignment.
    set!(ctx.s1, status: :verified)
    s4 = step(ctx, "Waits", %{assignee: "keel/fe"})
    {:ok, _} = Links.add(ctx.alice_scope, s4.ident, ctx.s2.ident, "depends_on")
    bob = human_actor(ctx.workspace, ctx.bob).name
    s5 = step(ctx, "Person", %{assignee: bob})
    set!(s5, status: :in_progress)
    s6 = step(ctx, "Qa", %{assignee: "keel/qa", depends_on: [ctx.s2.ident]})
    run_fixture(ctx.fe, %{task_id: s4.id, status: :deferred})

    states = states(ctx)

    assert Enum.map(Epics.step_states(ctx.epic), & &1.task.ident) ==
             Enum.map([ctx.s1, ctx.s2, ctx.s3, s4, s5, s6], & &1.ident)

    assert %{waiting_for: nil} = states[ctx.s1.ident]
    assert %{waiting_for: :start, blocked_by: []} = states[ctx.s2.ident]
    assert %{waiting_for: :assignment} = states[ctx.s3.ident]
    assert %{waiting_for: :prerequisites, blocked_by: [b4]} = states[s4.ident]
    assert %{waiting_for: :assignee} = states[s5.ident]
    assert %{waiting_for: :start, blocked_by: [b6]} = states[s6.ident]
    assert {b4, b6} == {ctx.s2.ident, ctx.s2.ident}
  end

  test "the other reasons, in order", ctx do
    done = step(ctx, "Done", %{assignee: "keel/fe"})
    set!(done, status: :done)
    rejected = step(ctx, "Rejected", %{assignee: "keel/fe"})
    set!(rejected, status: :rejected)
    question = step(ctx, "Question", %{assignee: "keel/fe"})
    set!(question, open_question: true)
    running = step(ctx, "Running", %{assignee: "keel/fe"})
    run_fixture(ctx.fe, %{task_id: running.id, status: :running})
    cancelled = step(ctx, "Cancelled", %{assignee: "keel/fe"})
    set!(cancelled, status: :cancelled)
    # Verified but not satisfied (a run still active on it): merge first.
    merging = step(ctx, "Merging", %{assignee: "keel/fe"})
    set!(merging, status: :verified)
    run_fixture(ctx.fe, %{task_id: merging.id, status: :running})
    # A person whose prerequisite is not done.
    bob = human_actor(ctx.workspace, ctx.bob).name
    waiting = step(ctx, "Person waits", %{assignee: bob, depends_on: [ctx.s3.ident]})

    states = states(ctx)
    assert states[done.ident].waiting_for == :verification
    assert states[rejected.ident].waiting_for == :requester
    assert states[question.ident].waiting_for == :answer
    assert states[running.ident].waiting_for == :run
    assert states[cancelled.ident].waiting_for == nil
    assert states[merging.ident].waiting_for == :merge
    assert states[waiting.ident].waiting_for == :prerequisites
  end

  test "an external agent assignee waits like a person", ctx do
    {:ok, ext} = Helmsman.Actors.identify(ctx.alice_scope, %{name: "claude-desktop"})
    s = step(ctx, "External", %{assignee: ext.name})
    assert states(ctx)[s.ident].waiting_for == :assignee
  end

  test "three queries, for 1 step and for 30", ctx do
    one = task_fixture(ctx.alice_scope, ctx.project.key, %{kind: :epic})
    {:ok, _} = Tasks.create(ctx.alice_scope, ctx.project.key, %{title: "a", epic: one.ident})
    {_, small} = QueryCount.count(fn -> Epics.step_states(one) end)

    for n <- 1..27, do: step(ctx, "Step #{n}", %{assignee: "keel/fe"})
    {states, large} = QueryCount.count(fn -> Epics.step_states(ctx.epic) end)
    assert length(states) == 30
    assert small == large
    assert large == 3
  end

  test "task_states: any tasks, in the given order, by the same rules", ctx do
    plain = task_fixture(ctx.alice_scope, ctx.project.key)
    {:ok, _} = Tasks.update(ctx.alice_scope, plain.ident, %{assignee: "keel/qa", start: false})
    drop_queued()

    {states, queries} =
      QueryCount.count(fn -> Epics.task_states([plain.id, ctx.s3.id, ctx.s2.id, -1]) end)

    assert Enum.map(states, &{&1.task.ident, &1.waiting_for}) == [
             {plain.ident, :start},
             {ctx.s3.ident, :assignment},
             {ctx.s2.ident, :start}
           ]

    assert queries == 3
    assert Epics.task_states([]) == []
  end
end
