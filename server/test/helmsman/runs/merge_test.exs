defmodule Helmsman.Runs.MergeTest do
  use Helmsman.DataCase, async: true

  import Helmsman.ApiTokensFixtures
  import Helmsman.ProjectsFixtures
  import Helmsman.RunsFixtures

  alias Helmsman.{Dispatch, Runs, Tasks, Tx}
  alias Helmsman.Runs.Run

  setup do
    ctx = dispatch_fixture(%{access: "workspace"})
    {carol, carol_scope} = member_scope_fixture(ctx.workspace)
    task = task_fixture(ctx.alice_scope, ctx.project.key, %{priority: :low})
    Map.merge(ctx, %{carol: carol, carol_scope: carol_scope, task: task})
  end

  defp attrs(ctx, overrides) do
    Map.merge(
      %{
        workspace_id: ctx.workspace.id,
        agent_id: ctx.agent.id,
        runtime_id: profile(ctx.agent).runtime_id,
        task_id: ctx.task.id,
        lane: :work,
        trigger: %{"kind" => "manual", "by_actor_id" => ctx.alice_scope.actor.id},
        root_initiator_user_id: ctx.alice.id,
        causal_agent_ids: [ctx.agent.id],
        capabilities: ["read", "write_task"],
        priority: 1
      },
      overrides
    )
  end

  defp upsert(attrs, opts \\ []), do: Tx.run(fn -> {:ok, Runs.upsert_pending(attrs, opts)} end)

  defp old_runs(ctx, n, attrs \\ %{}) do
    for _ <- 1..n//1,
        do: run_fixture(ctx.agent, Map.merge(%{task_id: ctx.task.id, status: :succeeded}, attrs))
  end

  test "assigned, then started by hand: one queued run with both triggers", ctx do
    {:ok, task} = Tasks.update(ctx.alice_scope, ctx.task.ident, %{assignee: "keel/dev"})
    assert [%{result: :queued, run_id: id}] = task.dispatch

    assert {:ok, %{outcome: %{result: :merged, run_id: ^id}, run: run}} =
             Dispatch.run_agent(ctx.carol_scope, "keel/dev", ctx.task.ident, nil)

    assert [%Run{id: ^id, status: :queued, root_initiator_user_id: root} = row] =
             runs_of(ctx.task.id)

    assert root == ctx.alice.id
    assert Enum.map(row.triggers, & &1["initiator_user_id"]) == [ctx.alice.id, ctx.carol.id]

    assert [%{kind: "assign", by: alice}, %{kind: "manual", by: carol}] = run.triggers
    assert alice.name == ctx.alice_scope.actor.name
    assert carol.name == ctx.carol_scope.actor.name
  end

  test "merging keeps the initiator, unites the chains, takes the higher priority", ctx do
    a = agent_fixture(ctx.workspace, ctx.alice, "keel/a")
    b = agent_fixture(ctx.workspace, ctx.alice, "keel/b")

    assert {:ok, {:queued, %Run{id: id}}} =
             upsert(attrs(ctx, %{causal_agent_ids: [b.id, ctx.agent.id], priority: 1}))

    assert {:ok, {:merged, %Run{id: ^id} = run}} =
             upsert(
               attrs(ctx, %{
                 root_initiator_user_id: ctx.carol.id,
                 causal_agent_ids: [a.id, ctx.agent.id],
                 priority: 3
               })
             )

    assert run.root_initiator_user_id == ctx.alice.id
    assert run.causal_agent_ids == Enum.sort([a.id, b.id, ctx.agent.id])
    assert run.priority == 3
    assert length(run.triggers) == 2

    # A lower priority does not lower it.
    assert {:ok, {:merged, %Run{priority: 3}}} = upsert(attrs(ctx, %{priority: 1}))
  end

  test "a claimed run takes no more triggers: a new run is queued", ctx do
    {:ok, {:queued, %Run{id: id}}} = upsert(attrs(ctx, %{}))
    Repo.update_all(from(r in Run, where: r.id == ^id), set: [status: :claimed])

    assert {:ok, {:queued, %Run{id: new_id}}} = upsert(attrs(ctx, %{}))
    assert new_id != id
    assert length(runs_of(ctx.task.id)) == 2
  end

  test "runs without a task never merge", ctx do
    assert {:ok, %{outcome: %{result: :queued, run_id: a}}} =
             Dispatch.run_agent(ctx.alice_scope, "keel/dev", nil, "look around")

    assert {:ok, %{outcome: %{result: :queued, run_id: b}}} =
             Dispatch.run_agent(ctx.alice_scope, "keel/dev", nil, "look around")

    assert a != b
  end

  describe "rate limit" do
    test "20 runs created in the hour, none queued: an assignment is rate_limited", ctx do
      old_runs(ctx, 20)
      {:ok, task} = Tasks.update(ctx.alice_scope, ctx.task.ident, %{assignee: "keel/dev"})
      assert [%{result: :skipped, reason: :rate_limited, run_id: nil}] = task.dispatch
      assert length(runs_of(ctx.task.id)) == 20
    end

    test "at the limit a queued run still takes the trigger", ctx do
      old_runs(ctx, 19)
      queued = run_fixture(ctx.agent, %{task_id: ctx.task.id})

      assert {:ok, %{outcome: %{result: :merged, run_id: id}}} =
               Dispatch.run_agent(ctx.alice_scope, "keel/dev", ctx.task.ident, nil)

      assert id == queued.id
      assert [%{"kind" => "manual"}] = Repo.get!(Run, id).triggers
    end

    test "older runs do not count; rate_limit?: false does not check", ctx do
      old_runs(ctx, 20, %{inserted_at: DateTime.add(DateTime.utc_now(), -3700, :second)})
      assert {:ok, {:queued, %Run{id: id}}} = upsert(attrs(ctx, %{}))
      Repo.update_all(from(r in Run, where: r.id == ^id), set: [status: :failed])
      old_runs(ctx, 20)

      assert {:ok, {:skipped, :rate_limited}} = upsert(attrs(ctx, %{}))
      assert {:ok, {:queued, %Run{}}} = upsert(attrs(ctx, %{}), rate_limit?: false)
    end

    test "the limit is configurable", ctx do
      Application.put_env(:helmsman, Helmsman.Dispatch, max_runs_per_task_per_hour: 2)
      on_exit(fn -> Application.delete_env(:helmsman, Helmsman.Dispatch) end)

      old_runs(ctx, 2)
      assert {:ok, {:skipped, :rate_limited}} = upsert(attrs(ctx, %{}))
    end
  end
end
