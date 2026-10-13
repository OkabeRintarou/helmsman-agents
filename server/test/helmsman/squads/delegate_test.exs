defmodule Helmsman.Squads.DelegateTest do
  # add-squads 4.1: `delegate` (squad-dispatch "委派", decision 8).
  use Helmsman.DataCase, async: true

  import Helmsman.AgentsFixtures
  import Helmsman.ProjectsFixtures
  import Helmsman.RunLifecycleFixtures
  import Helmsman.RunsFixtures
  import Helmsman.SquadsFixtures

  alias Helmsman.{Agents, Links, Squads, Tasks}
  alias Helmsman.Feedback.Entry
  alias Helmsman.Runs
  alias Helmsman.Runs.{Run, RunTokens}

  setup do
    ctx = squads_fixture()
    bos12 = task_fixture(ctx.alice_scope, ctx.project.key)
    Map.put(ctx, :bos12, bos12)
  end

  # The leader's run on `task`, assigned by `scope`, claimed and started;
  # its token scope.
  defp leader_run(ctx, task, scope \\ nil) do
    {:ok, _} = Tasks.update(scope || ctx.alice_scope, task.ident, %{assignee: "web-team"})
    {:ok, [spec]} = Runs.claim(dctx(ctx.lead), "http://localhost:4000")
    start!(ctx.lead, spec.run_id)
    Process.put(:run_token, spec.mcp.token)
    {token_scope(), Repo.get!(Run, spec.run_id)}
  end

  # The scope of the leader run's token, read again.
  defp token_scope do
    {:ok, scope} = RunTokens.scope(Process.get(:run_token))
    scope
  end

  defp member_runs(task, agent),
    do: Repo.all(from(r in Run, where: r.task_id == ^task.id and r.agent_id == ^agent.id))

  test "delegating the implementation: a queued work run of the member", ctx do
    {scope, leader} = leader_run(ctx, ctx.bos12)

    assert {:ok, %{result: :queued, run: summary}} =
             Squads.delegate(scope, ctx.bos12.ident, "keel/fe", " Implement the settings page ")

    assert summary.agent == "keel/fe"

    assert [%Run{status: :queued, lane: :work, squad_id: nil} = run] =
             member_runs(ctx.bos12, ctx.fe)

    assert run.root_initiator_user_id == ctx.alice.id
    assert run.causal_agent_ids == Enum.sort([ctx.lead.id, ctx.fe.id])

    lead_id = ctx.lead.id
    squad_id = ctx.squad.id
    leader_id = leader.id

    assert [
             %{
               "kind" => "delegated",
               "by_actor_id" => ^lead_id,
               "instructions" => "Implement the settings page",
               "squad_id" => ^squad_id,
               "leader_run_id" => ^leader_id,
               "causal_agent_ids" => [^lead_id, _fe]
             }
           ] = run.triggers

    refute "delegate" in run.capabilities

    # Claimed only after the leader's run ends.
    assert claim!(ctx.lead) == []
    finish!(ctx.lead, leader.id)
    assert claim!(ctx.lead) == [run.id]
  end

  test "an owner_only member the source may not trigger: cannot_invoke, no run", ctx do
    {scope, _leader} = leader_run(ctx, ctx.bos12)

    # The run acts for bob (who could not trigger keel/qa).
    Repo.update_all(from(r in Run, where: r.id == ^scope.run.id),
      set: [root_initiator_user_id: ctx.bob.id]
    )

    scope = token_scope()
    bob = human_actor(ctx.workspace, ctx.bob).name

    assert {:ok, %{result: :skipped, reason: :unauthorized, member: "keel/qa", initiator: ^bob}} =
             Squads.delegate(scope, ctx.bos12.ident, "keel/qa", "Test it")

    assert member_runs(ctx.bos12, ctx.qa) == []
  end

  test "not a member", ctx do
    managed_agent_fixture(ctx.carol_scope, %{name: "carol/dev", access: "workspace"})
    {scope, _leader} = leader_run(ctx, ctx.bos12)

    assert {:error, {:delegate, :not_member, {"web-team", ["keel/fe", "keel/review", "keel/qa"]}}} =
             Squads.delegate(scope, ctx.bos12.ident, "carol/dev", "Help")
  end

  test "a person member", ctx do
    {scope, _leader} = leader_run(ctx, ctx.bos12)
    bob = human_actor(ctx.workspace, ctx.bob).name

    assert {:error, {:delegate, :person_member, ^bob}} =
             Squads.delegate(scope, ctx.bos12.ident, bob, "Decide")
  end

  test "a delegated run is not a leader run: forbidden", ctx do
    run =
      run_fixture(ctx.fe, %{
        task_id: ctx.bos12.id,
        status: :running,
        capabilities: ["read", "write_task"]
      })

    {scope, _token} = run_scope_fixture(run)
    assert {:error, :forbidden} = Squads.delegate(scope, ctx.bos12.ident, "keel/review", "x")

    assert {:error, :forbidden} =
             Squads.delegate(ctx.alice_scope, ctx.bos12.ident, "keel/fe", "x")
  end

  test "the leader changed meanwhile: not_leader, nothing written", ctx do
    managed_agent_fixture(ctx.alice_scope, %{
      name: "keel/lead2",
      runtime_id: ctx.runtime_id,
      access: "workspace"
    })

    {scope, _leader} = leader_run(ctx, ctx.bos12)
    {:ok, _} = Squads.update(ctx.alice_scope, "web-team", %{leader: "keel/lead2"})

    assert {:error, {:delegate, :not_leader, "web-team"}} =
             Squads.delegate(scope, ctx.bos12.ident, "keel/fe", "x")

    assert member_runs(ctx.bos12, ctx.fe) == []
  end

  test "the checks in order: closed, not the squad's task, disabled", ctx do
    {scope, _leader} = leader_run(ctx, ctx.bos12)

    {:ok, _} = Squads.disable(ctx.alice_scope, "web-team")

    assert {:error, {:delegate, :squad_disabled, "web-team"}} =
             Squads.delegate(scope, ctx.bos12.ident, "keel/fe", "x")

    Repo.update_all(from(t in Tasks.Task, where: t.id == ^ctx.bos12.id),
      set: [assignee_id: ctx.agent.id]
    )

    assert {:error, {:delegate, :not_squad_task, "web-team"}} =
             Squads.delegate(scope, ctx.bos12.ident, "keel/fe", "x")

    Repo.update_all(from(t in Tasks.Task, where: t.id == ^ctx.bos12.id), set: [status: :done])

    assert {:error, {:delegate, :task_closed, _}} =
             Squads.delegate(scope, ctx.bos12.ident, "keel/fe", "x")
  end

  test "instructions and the run's own task", ctx do
    {scope, _leader} = leader_run(ctx, ctx.bos12)

    assert {:error, :instructions_required} =
             Squads.delegate(scope, ctx.bos12.ident, "keel/fe", "  ")

    assert {:error, {:invalid_instructions, :too_long}} =
             Squads.delegate(scope, ctx.bos12.ident, "keel/fe", String.duplicate("x", 8193))

    other = task_fixture(ctx.alice_scope, ctx.project.key)
    assert {:error, :forbidden} = Squads.delegate(scope, other.ident, "keel/fe", "x")
  end

  test "a task blocked by its dependencies: the member's run is queued", ctx do
    bos1 = task_fixture(ctx.alice_scope, ctx.project.key)
    {scope, _leader} = leader_run(ctx, ctx.bos12)
    {:ok, _} = Links.add(ctx.alice_scope, ctx.bos12.ident, bos1.ident, "depends_on")

    assert {:ok, %{result: :queued}} = Squads.delegate(scope, ctx.bos12.ident, "keel/fe", "x")
    assert [%Run{status: :queued}] = member_runs(ctx.bos12, ctx.fe)
  end

  test "a member already on the chain: loop_detected, committed with a note", ctx do
    {scope, _leader} = leader_run(ctx, ctx.bos12)

    Repo.update_all(from(r in Run, where: r.id == ^scope.run.id),
      set: [causal_agent_ids: [ctx.fe.id, ctx.lead.id]]
    )

    scope = token_scope()

    assert {:ok, %{result: :skipped, reason: :loop_detected}} =
             Squads.delegate(scope, ctx.bos12.ident, "keel/fe", "x")

    assert [%Entry{kind: :comment, content: "Did not start keel/fe" <> _}] =
             Repo.all(from(f in Entry, where: f.task_id == ^ctx.bos12.id))

    assert member_runs(ctx.bos12, ctx.fe) == []
  end

  test "two members delegated in turn: claimed in that order", ctx do
    {scope, leader} = leader_run(ctx, ctx.bos12)
    {:ok, %{run: fe}} = Squads.delegate(scope, ctx.bos12.ident, "keel/fe", "Implement")
    {:ok, %{run: review}} = Squads.delegate(scope, ctx.bos12.ident, "keel/review", "Review")

    finish!(ctx.lead, leader.id)
    assert claim!(ctx.lead) == [fe.id]
    start!(ctx.lead, fe.id)
    finish!(ctx.lead, fe.id)
    assert claim!(ctx.lead) |> Enum.member?(review.id)
  end

  test "a disabled member is not offered", ctx do
    {:ok, _} = Agents.disable(ctx.alice_scope, "keel/review")
    {scope, _leader} = leader_run(ctx, ctx.bos12)

    assert {:error, {:delegate, :not_member, {"web-team", ["keel/fe", "keel/qa"]}}} =
             Squads.delegate(scope, ctx.bos12.ident, "nobody", "x")

    assert {:ok, %{result: :skipped, reason: :agent_disabled}} =
             Squads.delegate(scope, ctx.bos12.ident, "keel/review", "x")
  end
end
