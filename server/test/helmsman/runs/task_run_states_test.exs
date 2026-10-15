defmodule Helmsman.Runs.TaskRunStatesTest do
  use Helmsman.DataCase, async: true
  import Helmsman.RunsFixtures
  import Helmsman.ProjectsFixtures
  import Helmsman.AgentsFixtures
  alias Helmsman.{QueryCount, Runs}

  setup do
    ctx = dispatch_fixture()
    {_user, viewer} = member_scope_fixture(ctx.workspace, :viewer)
    Map.put(ctx, :viewer, viewer)
  end

  test "priorities, claim order and dedup; latest success/cancellation suppresses failure", ctx do
    tasks = for _ <- 1..5, do: task_fixture(ctx.alice_scope, ctx.project.key)
    [active, queued, deferred, failed, ended] = tasks
    managed_agent_fixture(ctx.alice_scope, %{name: "keel/review"})
    review = agent_actor(ctx.workspace, "keel/review")
    at = DateTime.utc_now()
    run_fixture(ctx.agent, %{task_id: active.id, status: :running, claimed_at: at})
    run_fixture(review, %{task_id: active.id, status: :claimed, claimed_at: DateTime.add(at, -1)})

    run_fixture(ctx.agent, %{
      task_id: active.id,
      status: :cancelling,
      claimed_at: DateTime.add(at, 1)
    })

    run_fixture(ctx.agent, %{task_id: active.id, status: :queued})

    for task <- [queued, deferred, failed, ended],
        do: run_fixture(ctx.agent, %{task_id: task.id, status: :failed, finished_at: at})

    run_fixture(ctx.agent, %{task_id: queued.id, status: :queued})
    run_fixture(ctx.agent, %{task_id: deferred.id, status: :deferred})
    run_fixture(ctx.agent, %{task_id: ended.id, status: :cancelled, finished_at: at})

    assert {{:ok, states}, 1} =
             QueryCount.count(fn ->
               Runs.task_run_states(ctx.viewer, Enum.map(tasks, & &1.ident))
             end)

    assert states[active.ident] == %{status: :running, agents: ["keel/review", "keel/dev"]}
    assert states[queued.ident].status == :queued
    assert states[deferred.ident].status == :deferred
    assert states[failed.ident].status == :failed
    refute states[ended.ident]

    run_fixture(ctx.agent, %{
      task_id: failed.id,
      status: :succeeded,
      finished_at: DateTime.add(at, 1)
    })

    assert {:ok, %{}} = Runs.task_run_states(ctx.viewer, [failed.ident])
  end

  test "one statement for 1 or 200 ids, workspace isolation and permission", ctx do
    task = task_fixture(ctx.alice_scope, ctx.project.key)
    run_fixture(ctx.agent, %{task_id: task.id, status: :queued})
    ids = for n <- 1..201, do: "#{ctx.project.key}-#{n}"

    for list <- [[task.ident], Enum.take(ids, 200)] do
      assert {{:ok, states}, 1} =
               QueryCount.count(fn -> Runs.task_run_states(ctx.viewer, list) end)

      assert states[task.ident].status == :queued
    end

    assert {:error, :too_many} = Runs.task_run_states(ctx.viewer, ids)
    assert {:error, :forbidden} = Runs.task_run_states(%{ctx.viewer | role: nil}, [])
    other = dispatch_fixture()
    assert {:ok, %{}} = Runs.task_run_states(other.alice_scope, [task.ident])
  end
end
