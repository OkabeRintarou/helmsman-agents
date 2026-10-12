defmodule Helmsman.Dispatch.RunAgentTest do
  use Helmsman.DataCase, async: true

  import Helmsman.ApiTokensFixtures
  import Helmsman.ProjectsFixtures
  import Helmsman.RunsFixtures

  alias Helmsman.{Dispatch, Feedback, Tx}
  alias Helmsman.Runs.{Outcome, Run}
  alias Helmsman.Tasks.Task

  setup do
    ctx = dispatch_fixture()
    {bob, bob_scope} = member_scope_fixture(ctx.workspace)
    {_viewer, viewer_scope} = member_scope_fixture(ctx.workspace, :viewer)
    task = task_fixture(ctx.alice_scope, ctx.project.key)
    Map.merge(ctx, %{bob: bob, bob_scope: bob_scope, viewer_scope: viewer_scope, task: task})
  end

  test "with instructions on a task: a manual work run", ctx do
    assert {:ok, %{outcome: %Outcome{result: :queued, trigger: :manual, run_id: id}, run: run}} =
             Dispatch.run_agent(ctx.alice_scope, "keel/dev", ctx.task.ident, "  先补测试 \n")

    assert %{id: ^id, task: ident, agent: "keel/dev", lane: "work", status: "queued"} = run
    assert ident == ctx.task.ident
    assert [%{kind: "manual", instructions: "先补测试"}] = run.triggers
    assert [%Run{triggers: [%{"instructions" => "先补测试"}]}] = runs_of(ctx.task.id)
  end

  test "without a task, instructions are required", ctx do
    for instructions <- [nil, "", "  \n"] do
      assert {:error, :instructions_required} =
               Dispatch.run_agent(ctx.alice_scope, "keel/dev", nil, instructions)
    end

    assert {:ok, %{run: %{task: nil}}} =
             Dispatch.run_agent(ctx.alice_scope, "keel/dev", nil, "look around")
  end

  test "instructions are at most 8 KB", ctx do
    too_long = String.duplicate("a", 8193)

    assert {:error, {:invalid_instructions, :too_long}} =
             Dispatch.run_agent(ctx.alice_scope, "keel/dev", ctx.task.ident, too_long)

    assert {:error, {:invalid_instructions, :not_a_string}} =
             Dispatch.run_agent(ctx.alice_scope, "keel/dev", ctx.task.ident, 42)

    assert {:ok, _} =
             Dispatch.run_agent(
               ctx.alice_scope,
               "keel/dev",
               ctx.task.ident,
               String.duplicate("a", 8192)
             )
  end

  test "a run token, a viewer: forbidden", ctx do
    run = run_fixture(ctx.agent, %{task_id: ctx.task.id, status: :running})
    {run_scope, _token} = run_scope_fixture(run)

    assert {:error, :forbidden} =
             Dispatch.run_agent(run_scope, "keel/dev", ctx.task.ident, "again")

    assert {:error, :forbidden} =
             Dispatch.run_agent(ctx.viewer_scope, "keel/dev", ctx.task.ident, nil)

    assert [%Run{id: id}] = runs_of(ctx.task.id)
    assert id == run.id
  end

  test "unknown agent or task: not_found; an external agent: not_managed", ctx do
    agent_fixture(ctx.workspace, ctx.alice, "keel/external")

    assert {:error, :not_found} = Dispatch.run_agent(ctx.alice_scope, "nobody", nil, "x")

    assert {:error, :not_found} =
             Dispatch.run_agent(ctx.alice_scope, ctx.alice_scope.actor.name, nil, "x")

    assert {:error, :not_found} =
             Dispatch.run_agent(ctx.alice_scope, "keel/dev", "#{ctx.project.key}-999", nil)

    assert {:error, :not_managed} =
             Dispatch.run_agent(ctx.alice_scope, "keel/external", ctx.task.ident, nil)
  end

  test "a verified or cancelled task: task_closed", ctx do
    for status <- [:verified, :cancelled] do
      Repo.update_all(from(t in Task, where: t.id == ^ctx.task.id), set: [status: status])

      assert {:error, :task_closed} =
               Dispatch.run_agent(ctx.alice_scope, "keel/dev", ctx.task.ident, nil)
    end

    assert runs_of(ctx.task.id) == []
  end

  test "not dispatched is a result: the enclosing write commits", ctx do
    assert {:ok, {entry, %{outcome: outcome, run: nil}}} =
             Tx.run(fn ->
               {:ok, entry} = Feedback.add(ctx.bob_scope, ctx.task.ident, %{content: "hi"})
               {:ok, result} = Dispatch.run_agent(ctx.bob_scope, "keel/dev", ctx.task.ident, nil)
               {:ok, {entry, result}}
             end)

    assert %Outcome{result: :skipped, reason: :unauthorized, run_id: nil} = outcome
    assert {:ok, _} = Feedback.get(ctx.alice_scope, Feedback.Id.build(ctx.task.ident, entry.seq))
    assert runs_of(ctx.task.id) == []
  end
end
