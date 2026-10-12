defmodule Helmsman.Runs.ActiveAgentsTest do
  use Helmsman.DataCase, async: true

  import Helmsman.AgentsFixtures
  import Helmsman.ProjectsFixtures
  import Helmsman.RunsFixtures

  alias Helmsman.{QueryCount, Runs}

  setup do
    ctx = dispatch_fixture()
    {_viewer, viewer_scope} = member_scope_fixture(ctx.workspace, :viewer)
    Map.put(ctx, :viewer_scope, viewer_scope)
  end

  test "only tasks with an active run, with its agents", ctx do
    one = task_fixture(ctx.alice_scope, ctx.project.key)
    two = task_fixture(ctx.alice_scope, ctx.project.key)
    three = task_fixture(ctx.alice_scope, ctx.project.key)
    run_fixture(ctx.agent, %{task_id: one.id, status: :running, claimed_at: DateTime.utc_now()})
    run_fixture(ctx.agent, %{task_id: two.id, status: :succeeded})
    run_fixture(ctx.agent, %{task_id: three.id, status: :queued})

    assert {:ok, %{} = result} =
             Runs.active_agents(ctx.viewer_scope, [one.ident, two.ident, three.ident, "NOPE-9"])

    assert result == %{one.ident => ["keel/dev"]}
  end

  test "agents by claim time, without repeats, in one query", ctx do
    task = task_fixture(ctx.alice_scope, ctx.project.key)
    managed_agent_fixture(ctx.alice_scope, %{name: "keel/review"})
    review = agent_actor(ctx.workspace, "keel/review")
    at = DateTime.utc_now()

    run_fixture(ctx.agent, %{task_id: task.id, status: :claimed, claimed_at: DateTime.add(at, 2)})
    run_fixture(review, %{task_id: task.id, status: :running, claimed_at: at})

    run_fixture(ctx.agent, %{
      task_id: task.id,
      status: :cancelling,
      claimed_at: DateTime.add(at, 3)
    })

    {result, queries} =
      QueryCount.count(fn -> Runs.active_agents(ctx.viewer_scope, [task.ident]) end)

    assert result == {:ok, %{task.ident => ["keel/review", "keel/dev"]}}
    assert queries == 1
  end

  test "another workspace's tasks are absent", ctx do
    other = dispatch_fixture()
    task = task_fixture(other.alice_scope, other.project.key)
    run_fixture(other.agent, %{task_id: task.id, status: :running})

    assert {:ok, %{}} = Runs.active_agents(ctx.viewer_scope, [task.ident])
  end

  test "at most 200 idents", ctx do
    idents = for n <- 1..201, do: "#{ctx.project.key}-#{n}"
    assert {:error, :too_many} = Runs.active_agents(ctx.viewer_scope, idents)
    assert {:ok, %{}} = Runs.active_agents(ctx.viewer_scope, Enum.take(idents, 200))
  end

  test "needs :view_runs", ctx do
    assert {:error, :forbidden} = Runs.active_agents(%{ctx.viewer_scope | role: nil}, [])
  end
end
