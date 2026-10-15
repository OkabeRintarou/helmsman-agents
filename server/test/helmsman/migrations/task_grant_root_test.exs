defmodule Helmsman.Migrations.TaskGrantRootTest do
  # improve-squad-leader-orchestration 1.1: `task_grants.root_task_id` and
  # `epic_watch_checks` (decision 2), written directly to the database.
  use Helmsman.DataCase, async: true

  import Helmsman.AccountsFixtures
  import Helmsman.ProjectsFixtures
  import Helmsman.RunsFixtures
  import Helmsman.WorkspacesFixtures

  setup do
    ctx = dispatch_fixture()
    task = task_fixture(ctx.alice_scope, ctx.project.key)
    root = task_fixture(ctx.alice_scope, ctx.project.key)
    epic = task_fixture(ctx.alice_scope, ctx.project.key, %{kind: :epic})
    other_user = user_fixture()
    other = workspace_fixture(other_user)
    other_scope = workspace_scope_fixture(other_user, other)
    other_task = task_fixture(other_scope, project_fixture(other_scope).key)

    Map.merge(ctx, %{
      task: task,
      root: root,
      epic: epic,
      other_task: other_task,
      alice_actor: human_actor(ctx.workspace, ctx.alice).id
    })
  end

  defp grant(ctx, root_id) do
    Repo.query(
      "INSERT INTO task_grants (workspace_id, task_id, agent_id, kind, root_initiator_user_id, " <>
        "causal_agent_ids, granted_by_id, inserted_at, root_task_id) " <>
        "VALUES ($1, $2, $3, 'requested', $4, '{}', $3, now(), $5)",
      [ctx.workspace.id, ctx.task.id, ctx.agent.id, ctx.alice.id, root_id]
    )
  end

  defp check(ctx, epic_id) do
    Repo.query(
      "INSERT INTO epic_watch_checks (workspace_id, epic_id, checked_at, result) " <>
        "VALUES ($1, $2, now(), 'not_stalled')",
      [ctx.workspace.id, epic_id]
    )
  end

  defp assert_fk(result),
    do: assert({:error, %Postgrex.Error{postgres: %{code: :foreign_key_violation}}} = result)

  # Like the replace import: a task's own history first.
  defp delete_task!(id) do
    Repo.query!("DELETE FROM task_events WHERE task_id = $1", [id])
    Repo.query!("DELETE FROM tasks WHERE id = $1", [id])
  end

  test "a root and an epic of another workspace are refused", ctx do
    assert_fk(grant(ctx, ctx.other_task.id))
    assert_fk(check(ctx, ctx.other_task.id))
    assert {:ok, _} = grant(ctx, ctx.root.id)
    assert {:ok, _} = check(ctx, ctx.epic.id)
  end

  test "deleting the root deletes the grant", ctx do
    {:ok, _} = grant(ctx, ctx.root.id)
    delete_task!(ctx.root.id)

    assert %{rows: [[0]]} =
             Repo.query!("SELECT count(*) FROM task_grants WHERE task_id = $1", [ctx.task.id])
  end

  test "deleting the epic deletes its check; one check per epic", ctx do
    {:ok, _} = check(ctx, ctx.epic.id)

    assert {:error, %Postgrex.Error{postgres: %{constraint: "epic_watch_checks_epic_id_index"}}} =
             check(ctx, ctx.epic.id)

    delete_task!(ctx.epic.id)
    assert %{rows: [[0]]} = Repo.query!("SELECT count(*) FROM epic_watch_checks")
  end
end
