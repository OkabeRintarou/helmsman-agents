defmodule Helmsman.Feedback.SchemaConstraintsTest do
  # Inserts raw rows, bypassing changesets, to prove the database itself
  # rejects invalid feedback.
  use Helmsman.DataCase, async: true

  setup do
    acme = insert!("workspaces", %{slug: "acme", name: "Acme"})
    beta = insert!("workspaces", %{slug: "beta", name: "Beta"})
    alice = insert!("actors", %{workspace_id: acme, kind: "squad", name: "alice"})
    bob = insert!("actors", %{workspace_id: beta, kind: "squad", name: "bob"})
    project = insert!("projects", %{workspace_id: acme, key: "BOS", name: "Bosun"})

    task =
      insert!("tasks", %{
        workspace_id: acme,
        project_id: project,
        seq: 1,
        ident: "BOS-1",
        title: "Title",
        created_by_id: alice
      })

    %{acme: acme, beta: beta, alice: alice, bob: bob, task: task}
  end

  defp insert!(table, row) do
    now = DateTime.utc_now()

    stamps =
      if table == "feedback",
        do: %{inserted_at: now},
        else: %{inserted_at: now, updated_at: now}

    {1, [%{id: id}]} = Repo.insert_all(table, [Map.merge(stamps, row)], returning: [:id])
    id
  end

  # Runs the insert in a savepoint so the sandbox transaction stays usable,
  # and returns the name of the violated constraint.
  defp rejected(table, row) do
    error =
      assert_raise Postgrex.Error, fn ->
        Repo.transaction(fn -> insert!(table, row) end)
      end

    error.postgres.constraint
  end

  defp feedback(ctx, attrs) do
    Map.merge(
      %{
        workspace_id: ctx.acme,
        task_id: ctx.task,
        seq: 1,
        thread_seq: 1,
        author_id: ctx.alice,
        kind: "comment",
        content: "Hello"
      },
      attrs
    )
  end

  test "a valid row has defaults", ctx do
    id = insert!("feedback", feedback(ctx, %{}))

    assert %{rows: [["active", [], nil]]} =
             Repo.query!(
               "SELECT status, mentions, superseded_by_id FROM feedback WHERE id = $1",
               [id]
             )
  end

  test "rejects unknown kinds and statuses", ctx do
    assert rejected("feedback", feedback(ctx, %{kind: "note"})) == "feedback_kind_check"
    assert rejected("feedback", feedback(ctx, %{status: "deleted"})) == "feedback_status_check"
  end

  test "superseded and superseded_by_id go together", ctx do
    assert rejected("feedback", feedback(ctx, %{status: "superseded"})) ==
             "feedback_superseded_check"

    first = insert!("feedback", feedback(ctx, %{}))

    assert rejected("feedback", feedback(ctx, %{seq: 2, thread_seq: 2, superseded_by_id: first})) ==
             "feedback_superseded_check"
  end

  test "content is 1 byte to 64 KB", ctx do
    assert rejected("feedback", feedback(ctx, %{content: ""})) == "feedback_content_size"

    assert rejected("feedback", feedback(ctx, %{content: String.duplicate("a", 65_537)})) ==
             "feedback_content_size"

    assert insert!("feedback", feedback(ctx, %{content: String.duplicate("a", 65_536)}))
  end

  test "the place is never after the number", ctx do
    assert rejected("feedback", feedback(ctx, %{seq: 1, thread_seq: 2})) ==
             "feedback_thread_seq_check"
  end

  test "numbers are unique within a task", ctx do
    insert!("feedback", feedback(ctx, %{}))
    assert rejected("feedback", feedback(ctx, %{})) == "feedback_task_id_seq_index"
  end

  test "the author belongs to the workspace", ctx do
    assert rejected("feedback", feedback(ctx, %{author_id: ctx.bob})) ==
             "feedback_author_id_fkey"
  end

  test "a record is revised at most once", ctx do
    first = insert!("feedback", feedback(ctx, %{}))
    insert!("feedback", feedback(ctx, %{seq: 2, thread_seq: 1, supersedes_id: first}))

    assert rejected("feedback", feedback(ctx, %{seq: 3, thread_seq: 1, supersedes_id: first})) ==
             "feedback_supersedes_id_index"
  end

  test "history entries refer to feedback of their workspace", ctx do
    first = insert!("feedback", feedback(ctx, %{}))
    beta_project = insert!("projects", %{workspace_id: ctx.beta, key: "BOS", name: "B"})

    beta_task =
      insert!("tasks", %{
        workspace_id: ctx.beta,
        project_id: beta_project,
        seq: 1,
        ident: "BOS-1",
        title: "T",
        created_by_id: ctx.bob
      })

    row = %{
      workspace_id: ctx.beta,
      task_id: beta_task,
      to_status: "new",
      actor_id: ctx.bob,
      feedback_id: first
    }

    error =
      assert_raise Postgrex.Error, fn ->
        Repo.transaction(fn ->
          Repo.insert_all("task_events", [Map.put(row, :inserted_at, DateTime.utc_now())])
        end)
      end

    assert error.postgres.constraint == "task_events_feedback_id_fkey"
  end
end
