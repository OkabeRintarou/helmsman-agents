defmodule Helmsman.Runs.ConstraintsTest do
  use Helmsman.DataCase, async: true

  import Helmsman.AccountsFixtures
  import Helmsman.AgentsFixtures
  import Helmsman.ProjectsFixtures
  import Helmsman.RunsFixtures
  import Helmsman.WorkspacesFixtures

  setup do
    ctx = dispatch_fixture()
    task = task_fixture(ctx.alice_scope, ctx.project.key)
    profile = profile(ctx.agent)

    # A second workspace with its own agent, runtime and task.
    bob = user_fixture()
    other = workspace_fixture(bob)
    bob_scope = workspace_scope_fixture(bob, other)
    managed_agent_fixture(bob_scope, %{name: "other/dev"})
    other_agent = agent_actor(other, "other/dev")
    other_project = project_fixture(bob_scope)
    other_task = task_fixture(bob_scope, other_project.key)

    Map.merge(ctx, %{
      task: task,
      profile: profile,
      other: other,
      other_agent: other_agent,
      other_runtime_id: profile(other_agent).runtime_id,
      other_task: other_task
    })
  end

  defp row(ctx, attrs \\ %{}) do
    now = DateTime.utc_now()

    Map.merge(
      %{
        workspace_id: ctx.workspace.id,
        agent_id: ctx.agent.id,
        runtime_id: ctx.profile.runtime_id,
        task_id: ctx.task.id,
        lane: "work",
        status: "queued",
        triggers: [],
        root_initiator_user_id: ctx.alice.id,
        causal_agent_ids: [ctx.agent.id],
        capabilities: ["read"],
        priority: 2,
        inserted_at: now,
        updated_at: now
      },
      attrs
    )
  end

  defp insert(row), do: Repo.insert_all("runs", [row], returning: [:id])

  defp assert_rejected(fun) when is_function(fun, 0) do
    assert_raise Postgrex.Error, fn -> Repo.transact(fn -> {:ok, fun.()} end) end
  end

  defp assert_rejected(row), do: assert_rejected(fn -> insert(row) end)

  test "a valid row is accepted", ctx do
    assert {1, [%{id: _}]} = insert(row(ctx))
    assert {1, _} = insert(row(ctx, %{task_id: nil}))
  end

  test "lane, status, failure reason, capabilities, priority and triggers are checked", ctx do
    for attrs <- [
          %{lane: "other"},
          %{status: "paused"},
          %{failure_reason: "bored"},
          %{capabilities: ["read", "admin"]},
          %{priority: 4},
          %{priority: 0},
          %{triggers: %{"kind" => "assign"}}
        ] do
      assert_rejected(row(ctx, attrs))
    end

    assert {1, _} = insert(row(ctx, %{status: "failed", failure_reason: "obsolete"}))

    assert {1, _} =
             insert(
               row(ctx, %{
                 status: "running",
                 capabilities: ["read", "write_task", "create_tasks", "delegate"]
               })
             )
  end

  test "agent, task, runtime and source runs stay in their workspace", ctx do
    assert_rejected(row(ctx, %{agent_id: ctx.other_agent.id}))
    assert_rejected(row(ctx, %{task_id: ctx.other_task.id}))
    assert_rejected(row(ctx, %{runtime_id: ctx.other_runtime_id}))

    {1, [%{id: other_run}]} =
      insert(
        row(ctx, %{
          workspace_id: ctx.other.id,
          agent_id: ctx.other_agent.id,
          runtime_id: ctx.other_runtime_id,
          task_id: ctx.other_task.id
        })
      )

    assert_rejected(fn ->
      Repo.query!(
        "INSERT INTO feedback (workspace_id, task_id, seq, thread_seq, author_id, kind, " <>
          "content, source_run_id, inserted_at) " <>
          "VALUES ($1, $2, 99, 99, $3, 'comment', 'x', $4, now())",
        [ctx.workspace.id, ctx.task.id, ctx.agent.id, other_run]
      )
    end)

    assert_rejected(fn ->
      Repo.query!(
        "INSERT INTO task_events (workspace_id, task_id, to_status, actor_id, source_run_id, " <>
          "inserted_at) VALUES ($1, $2, 'new', $3, $4, now())",
        [ctx.workspace.id, ctx.task.id, ctx.agent.id, other_run]
      )
    end)
  end

  test "one pending run per (task, agent, lane)", ctx do
    assert {1, _} = insert(row(ctx))
    assert_rejected(row(ctx, %{status: "deferred"}))
    assert {1, _} = insert(row(ctx, %{status: "running"}))
    assert {1, _} = insert(row(ctx, %{lane: "reply"}))
    assert {1, _} = insert(row(ctx, %{task_id: nil}))
    assert {1, _} = insert(row(ctx, %{task_id: nil}))
  end

  test "one token per run, unique hashes", ctx do
    {1, [%{id: run_id}]} = insert(row(ctx, %{status: "claimed"}))
    now = DateTime.utc_now()
    token = %{run_id: run_id, token_hash: "h1", expires_at: now, inserted_at: now}
    assert {1, _} = Repo.insert_all("run_tokens", [token])
    assert_rejected(fn -> Repo.insert_all("run_tokens", [%{token | token_hash: "h2"}]) end)

    {1, [%{id: run2}]} = insert(row(ctx, %{status: "running"}))
    assert_rejected(fn -> Repo.insert_all("run_tokens", [%{token | run_id: run2}]) end)
  end

  test "one grant per (task, agent, kind), kinds checked", ctx do
    grant = %{
      workspace_id: ctx.workspace.id,
      task_id: ctx.task.id,
      agent_id: ctx.agent.id,
      kind: "assign",
      root_initiator_user_id: ctx.alice.id,
      causal_agent_ids: [ctx.agent.id],
      granted_by_id: ctx.alice_scope.actor.id,
      inserted_at: DateTime.utc_now()
    }

    assert {1, _} = Repo.insert_all("task_grants", [grant])

    for bad <- [grant, %{grant | kind: "delegate"}, %{grant | agent_id: ctx.other_agent.id}] do
      assert_rejected(fn -> Repo.insert_all("task_grants", [bad]) end)
    end
  end
end
