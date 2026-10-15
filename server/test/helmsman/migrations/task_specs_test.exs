defmodule Helmsman.Migrations.TaskSpecsTest do
  # add-spec-workflow 1.1: the tables and constraints of decision 2, written
  # directly to the database.
  use Helmsman.DataCase, async: true

  import Helmsman.AccountsFixtures
  import Helmsman.ProjectsFixtures
  import Helmsman.RunsFixtures
  import Helmsman.WorkspacesFixtures

  setup do
    ctx = dispatch_fixture()
    task = task_fixture(ctx.alice_scope, ctx.project.key)
    alice = human_actor(ctx.workspace, ctx.alice).id
    other_user = user_fixture()
    other = workspace_fixture(other_user)
    other_scope = workspace_scope_fixture(other_user, other)
    other_task = task_fixture(other_scope, project_fixture(other_scope).key)

    Map.merge(ctx, %{
      task: task,
      alice_actor: alice,
      other: other,
      other_actor: human_actor(other, other_user).id,
      other_task: other_task
    })
  end

  defp insert_spec(workspace_id, task_id, author_id, change_id, status \\ "draft") do
    Repo.query(
      "INSERT INTO task_specs (workspace_id, task_id, change_id, created_by_id, status, " <>
        "inserted_at, updated_at) VALUES ($1, $2, $3, $4, $5, now(), now()) RETURNING id",
      [workspace_id, task_id, change_id, author_id, status]
    )
  end

  defp insert_version(ctx, spec_id, number) do
    %{rows: [[id]]} =
      Repo.query!(
        "INSERT INTO task_spec_versions (workspace_id, spec_id, number, author_id, inserted_at) " <>
          "VALUES ($1, $2, $3, $4, now()) RETURNING id",
        [ctx.workspace.id, spec_id, number, ctx.alice_actor]
      )

    id
  end

  defp insert_request(ctx, spec_id, number, version_id, status) do
    reason = if status == "cancelled", do: "withdrawn"

    Repo.query(
      "INSERT INTO task_spec_review_requests (workspace_id, spec_id, number, version_id, " <>
        "reviewer_id, requested_by_id, status, close_reason, inserted_at) " <>
        "VALUES ($1, $2, $3, $4, $5, $6, $7, $8, now())",
      [
        ctx.workspace.id,
        spec_id,
        number,
        version_id,
        ctx.agent.id,
        ctx.alice_actor,
        status,
        reason
      ]
    )
  end

  defp spec!(ctx) do
    {:ok, %{rows: [[id]]}} = insert_spec(ctx.workspace.id, ctx.task.id, ctx.alice_actor, "bos-1")
    id
  end

  defp assert_fk(result),
    do: assert({:error, %Postgrex.Error{postgres: %{code: :foreign_key_violation}}} = result)

  defp assert_constraint(result, name),
    do: assert({:error, %Postgrex.Error{postgres: %{constraint: ^name}}} = result)

  test "the task and the author must be of the spec's workspace", ctx do
    assert_fk(insert_spec(ctx.workspace.id, ctx.other_task.id, ctx.alice_actor, "x-1"))

    assert_fk(insert_spec(ctx.workspace.id, ctx.task.id, ctx.other_actor, "x-1"))
    assert {:ok, _} = insert_spec(ctx.workspace.id, ctx.task.id, ctx.alice_actor, "x-1")
  end

  test "a task has at most one spec and change ids are unique per workspace", ctx do
    spec!(ctx)

    assert_constraint(
      insert_spec(ctx.workspace.id, ctx.task.id, ctx.alice_actor, "bos-2"),
      "task_specs_task_id_index"
    )

    second = task_fixture(ctx.alice_scope, ctx.project.key)

    assert_constraint(
      insert_spec(ctx.workspace.id, second.id, ctx.alice_actor, "bos-1"),
      "task_specs_workspace_id_change_id_index"
    )

    # The same change id in another workspace is fine.
    assert {:ok, _} = insert_spec(ctx.other.id, ctx.other_task.id, ctx.other_actor, "bos-1")
  end

  test "a change id must be kebab-case", ctx do
    assert_constraint(
      insert_spec(ctx.workspace.id, ctx.task.id, ctx.alice_actor, "Bad_Id"),
      "task_specs_change_id_format"
    )
  end

  test "a finalized spec has a final version", ctx do
    assert_constraint(
      insert_spec(ctx.workspace.id, ctx.task.id, ctx.alice_actor, "bos-1", "finalized"),
      "task_specs_final_version_check"
    )

    id = spec!(ctx)

    assert_constraint(
      Repo.query("UPDATE task_specs SET status = 'pending_approval' WHERE id = $1", [id]),
      "task_specs_proposal_check"
    )

    assert {:ok, _} =
             Repo.query(
               "UPDATE task_specs SET status = 'finalized', final_version = 1 WHERE id = $1",
               [id]
             )
  end

  test "one requested review per version and reviewer", ctx do
    spec_id = spec!(ctx)
    version_id = insert_version(ctx, spec_id, 1)

    assert {:ok, _} = insert_request(ctx, spec_id, 1, version_id, "requested")

    assert_constraint(
      insert_request(ctx, spec_id, 2, version_id, "requested"),
      "task_spec_review_requests_pending_index"
    )

    assert {:ok, _} = insert_request(ctx, spec_id, 3, version_id, "submitted")
    assert {:ok, _} = insert_request(ctx, spec_id, 4, version_id, "cancelled")
  end

  test "deleting the task deletes the spec and every child row", ctx do
    spec_id = spec!(ctx)
    version_id = insert_version(ctx, spec_id, 1)

    %{rows: [[blob_id]]} =
      Repo.query!(
        "INSERT INTO task_spec_blobs (workspace_id, spec_id, sha256, content, bytes) " <>
          "VALUES ($1, $2, '\\x00', 'x', 1) RETURNING id",
        [ctx.workspace.id, spec_id]
      )

    Repo.query!(
      "INSERT INTO task_spec_files (workspace_id, version_id, path, blob_id) " <>
        "VALUES ($1, $2, 'proposal.md', $3)",
      [ctx.workspace.id, version_id, blob_id]
    )

    %{rows: [[review_id]]} =
      Repo.query!(
        "INSERT INTO task_spec_reviews (workspace_id, spec_id, number, version_id, reviewer_id, " <>
          "verdict, inserted_at) VALUES ($1, $2, 1, $3, $4, 'fail', now()) RETURNING id",
        [ctx.workspace.id, spec_id, version_id, ctx.agent.id]
      )

    Repo.query!(
      "INSERT INTO task_spec_review_requests (workspace_id, spec_id, number, version_id, " <>
        "reviewer_id, requested_by_id, status, review_id, inserted_at) " <>
        "VALUES ($1, $2, 1, $3, $4, $5, 'submitted', $6, now())",
      [ctx.workspace.id, spec_id, version_id, ctx.agent.id, ctx.alice_actor, review_id]
    )

    %{rows: [[issue_id]]} =
      Repo.query!(
        "INSERT INTO task_spec_issues (workspace_id, spec_id, review_id, number, severity, " <>
          "body, updated_at) VALUES ($1, $2, $3, 1, 'P1', 'x', now()) RETURNING id",
        [ctx.workspace.id, spec_id, review_id]
      )

    Repo.query!(
      "INSERT INTO task_spec_issue_notes (workspace_id, issue_id, number, author_id, kind, " <>
        "inserted_at) VALUES ($1, $2, 1, $3, 'comment', now())",
      [ctx.workspace.id, issue_id, ctx.alice_actor]
    )

    Repo.query!(
      "INSERT INTO task_spec_events (workspace_id, spec_id, number, actor_id, action, " <>
        "inserted_at) VALUES ($1, $2, 1, $3, 'created', now())",
      [ctx.workspace.id, spec_id, ctx.alice_actor]
    )

    # Like the replace import: the task's own history first, then the task.
    Repo.query!("DELETE FROM task_events WHERE task_id = $1", [ctx.task.id])
    Repo.query!("DELETE FROM tasks WHERE id = $1", [ctx.task.id])

    for table <-
          ~w(task_specs task_spec_blobs task_spec_versions task_spec_files task_spec_reviews
             task_spec_review_requests task_spec_issues task_spec_issue_notes task_spec_events) do
      assert %{rows: [[0]]} = Repo.query!("SELECT count(*) FROM #{table}"), table
    end
  end

  test "versions have no finalize columns" do
    %{rows: rows} =
      Repo.query!(
        "SELECT column_name FROM information_schema.columns WHERE table_name = 'task_spec_versions'"
      )

    columns = List.flatten(rows)
    assert "number" in columns
    refute Enum.any?(columns, &String.contains?(&1, "final"))
  end

  test "projects and squads have a spec finalize mode", ctx do
    assert %{rows: [["approval"]]} =
             Repo.query!("SELECT spec_finalize FROM projects WHERE id = $1", [ctx.project.id])

    assert_constraint(
      Repo.query("UPDATE projects SET spec_finalize = 'x' WHERE id = $1", [ctx.project.id]),
      "projects_spec_finalize_check"
    )
  end
end
