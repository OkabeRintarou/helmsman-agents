defmodule Helmsman.Squads.StartTaskTest do
  # improve-squad-leader-orchestration 1.5: squad-orchestration 「开工」
  # (decision 5).
  use Helmsman.DataCase, async: true

  import Helmsman.OrchestrationFixtures
  import Helmsman.RunsFixtures

  alias Helmsman.Actors.Actor
  alias Helmsman.{Agents, Links, Repo, Squads, Tasks}
  alias Helmsman.Feedback.Entry
  alias Helmsman.Runs.{Run, TaskGrant}

  setup do
    ctx = orchestration_fixture()
    {scope, run} = leader_run(ctx, ctx.lead, ctx.s1)
    Map.merge(ctx, %{scope: scope, run: run})
  end

  defp runs(task),
    do:
      Repo.all(from(r in Run, where: r.task_id == ^task.id and r.status in [:queued, :deferred]))

  defp notes(task),
    do:
      Repo.all(
        from(f in Entry,
          join: a in Actor,
          on: a.id == f.author_id,
          where: f.task_id == ^task.id and a.kind == :system,
          order_by: f.seq,
          select: f
        )
      )

  defp grants(task),
    do: Repo.all(from(g in TaskGrant, where: g.task_id == ^task.id and g.kind == :assign))

  test "starting a step created with start: false", ctx do
    assert {:ok, %{result: :queued, assignee: "keel/review", run: %{id: id}}} =
             Squads.start_task(ctx.scope, ctx.s2.ident, "  Interfaces are in core/src/bus.rs ")

    assert %Run{lane: :work, root_initiator_user_id: initiator, triggers: [trigger]} =
             Repo.get!(Run, id)

    assert initiator == ctx.alice.id

    assert %{
             "kind" => "assign",
             "orchestrated" => true,
             "instructions" => "Interfaces are in core/src/bus.rs"
           } = trigger

    assert trigger["orchestrator_run_id"] == ctx.run.id

    assert [%Entry{content: content, dispatch: [%{"result" => "queued"}]}] = notes(ctx.s2)

    assert content ==
             "Orchestration by keel/lead (squad web-team, run #{ctx.run.id} on #{ctx.s1.ident}, " <>
               "root #{ctx.epic.ident}): started keel/review on #{ctx.s2.ident}.\n" <>
               "> Interfaces are in core/src/bus.rs"
  end

  test "prerequisites not done: deferred", ctx do
    {:ok, _} = Links.add(ctx.scope, ctx.s2.ident, ctx.s3.ident, "depends_on")

    assert {:ok, %{result: :deferred, blocked_by: [blocker]}} =
             Squads.start_task(ctx.scope, ctx.s2.ident)

    assert blocker == ctx.s3.ident
    assert [%Run{status: :deferred}] = runs(ctx.s2)
  end

  test "already queued: the run, no new trigger, no note", ctx do
    {:ok, %{run: %{id: id}}} = Squads.start_task(ctx.scope, ctx.s2.ident)

    assert {:ok, %{result: :already, run: %{id: ^id}}} =
             Squads.start_task(ctx.scope, ctx.s2.ident)

    assert [%Run{triggers: [_]}] = runs(ctx.s2)
    assert length(notes(ctx.s2)) == 1
  end

  test "assignee rules", ctx do
    assert {:error, {:orchestration, :no_assignee, _}} =
             Squads.start_task(ctx.scope, ctx.s3.ident)

    bob = human_actor(ctx.workspace, ctx.bob).name
    {:ok, _} = Tasks.update(ctx.scope, ctx.s3.ident, %{assignee: bob})

    assert {:error, {:orchestration, :person_assignee, _, ^bob}} =
             Squads.start_task(ctx.scope, ctx.s3.ident)

    {:ok, _} = Tasks.update(ctx.alice_scope, ctx.s3.ident, %{assignee: "keel/dev", start: false})

    assert {:error, {:orchestration, :not_member, "keel/dev", "web-team"}} =
             Squads.start_task(ctx.scope, ctx.s3.ident)
  end

  test "scope, root, closed task", ctx do
    assert {:error, {:orchestration, :root, _}} = Squads.start_task(ctx.scope, ctx.epic.ident)

    other = Helmsman.ProjectsFixtures.task_fixture(ctx.alice_scope, ctx.project.key)
    assert {:error, {:orchestration, :outside, _, _}} = Squads.start_task(ctx.scope, other.ident)

    {:ok, _} = Tasks.transition(ctx.alice_scope, ctx.s2.ident, :cancelled)
    assert {:error, :task_closed} = Squads.start_task(ctx.scope, ctx.s2.ident)
  end

  test "others are forbidden", ctx do
    assert {:error, :forbidden} = Squads.start_task(ctx.alice_scope, ctx.s2.ident)
    {scope, _} = leader_run(ctx, ctx.fe, ctx.s1, squad: false)
    assert {:error, :forbidden} = Squads.start_task(scope, ctx.s2.ident)
  end

  test "the source may not trigger the member: skipped, committed, noted", ctx do
    {:ok, _} = Agents.update(ctx.alice_scope, "keel/review", %{access: "owner_only"})
    run = Repo.get!(Run, ctx.run.id)
    Repo.update!(Ecto.Changeset.change(run, root_initiator_user_id: ctx.carol.id))
    scope = %{ctx.scope | run: Repo.get!(Run, ctx.run.id)}
    before = grants(ctx.s2)

    assert {:ok, %{result: :skipped, reason: :unauthorized}} =
             Squads.start_task(scope, ctx.s2.ident)

    assert [%Entry{dispatch: [%{"result" => "skipped", "reason" => "unauthorized"}]}] =
             notes(ctx.s2)

    assert grants(ctx.s2) == before
  end

  test "a member on the chain: loop_detected", ctx do
    Repo.update_all(from(r in Run, where: r.id == ^ctx.run.id),
      set: [causal_agent_ids: [ctx.review.id, ctx.lead.id]]
    )

    scope = %{ctx.scope | run: Repo.get!(Run, ctx.run.id)}

    assert {:ok, %{result: :skipped, reason: :loop_detected}} =
             Squads.start_task(scope, ctx.s2.ident)
  end

  test "the assign grant: inserted when missing, never replaced", ctx do
    # carol may not trigger alice's owner_only keel/qa: her assignment
    # records no grant.
    {:ok, _} = Tasks.update(ctx.carol_scope, ctx.s3.ident, %{assignee: "keel/qa", start: false})
    assert grants(ctx.s3) == []
    {:ok, %{result: :queued}} = Squads.start_task(ctx.scope, ctx.s3.ident)
    assert [%TaskGrant{granted_by_id: by, root_initiator_user_id: initiator}] = grants(ctx.s3)
    assert {by, initiator} == {ctx.lead.id, ctx.alice.id}

    {:ok, _} = Tasks.update(ctx.alice_scope, ctx.s2.ident, %{assignee: "keel/qa", start: false})
    [%TaskGrant{granted_by_id: alice_actor}] = grants(ctx.s2)
    {:ok, _} = Squads.start_task(ctx.scope, ctx.s2.ident)
    assert [%TaskGrant{granted_by_id: ^alice_actor}] = grants(ctx.s2)
  end

  test "instructions over 8 KB", ctx do
    assert {:error, {:invalid_instructions, :too_long}} =
             Squads.start_task(ctx.scope, ctx.s2.ident, String.duplicate("x", 8193))

    assert {:ok, _} = Squads.start_task(ctx.scope, ctx.s2.ident, String.duplicate("x", 8192))
  end
end
