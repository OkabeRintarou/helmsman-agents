defmodule Helmsman.Tasks.SchemaConstraintsTest do
  # Inserts raw rows, bypassing changesets, to prove the database itself
  # rejects invalid projects, tasks and history entries.
  use Helmsman.DataCase, async: true

  setup do
    acme = insert!("workspaces", %{slug: "acme", name: "Acme"})
    beta = insert!("workspaces", %{slug: "beta", name: "Beta"})
    alice = insert!("actors", %{workspace_id: acme, kind: "squad", name: "alice"})
    bob = insert!("actors", %{workspace_id: beta, kind: "squad", name: "bob"})
    project = insert!("projects", %{workspace_id: acme, key: "BOS", name: "Bosun"})
    other_project = insert!("projects", %{workspace_id: beta, key: "BOS", name: "Bosun"})

    %{
      acme: acme,
      alice: alice,
      bob: bob,
      project: project,
      other_project: other_project
    }
  end

  defp insert!(table, row) do
    now = DateTime.utc_now()

    stamps =
      if table == "task_events",
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

  defp task(ctx, attrs) do
    Map.merge(
      %{
        workspace_id: ctx.acme,
        project_id: ctx.project,
        seq: 1,
        ident: "BOS-1",
        title: "Title",
        created_by_id: ctx.alice
      },
      attrs
    )
  end

  describe "projects" do
    test "rejects invalid keys", %{acme: acme} do
      for key <- ["1BOS", "B", "BOS-X", "bos", "ABCDEFGHIJK", ""] do
        assert rejected("projects", %{workspace_id: acme, key: key, name: "X"}) ==
                 "projects_key_format"
      end

      assert insert!("projects", %{workspace_id: acme, key: "ABCDEFGHIJ", name: "X"})
    end

    test "keys are unique within a workspace", %{acme: acme} do
      assert rejected("projects", %{workspace_id: acme, key: "BOS", name: "X"}) ==
               "projects_workspace_id_key_index"
    end

    test "rejects names of 0 or 81 characters", %{acme: acme} do
      for name <- ["", String.duplicate("n", 81)] do
        assert rejected("projects", %{workspace_id: acme, key: "NEW", name: name}) ==
                 "projects_name_length"
      end
    end

    test "rejects descriptions over 64 KB and a negative task_seq", %{acme: acme} do
      assert rejected("projects", %{
               workspace_id: acme,
               key: "NEW",
               name: "X",
               description: String.duplicate("é", 32_769)
             }) == "projects_description_size"

      assert rejected("projects", %{workspace_id: acme, key: "NEW", name: "X", task_seq: -1}) ==
               "projects_task_seq_check"
    end
  end

  describe "tasks" do
    test "accepts a valid task with defaults", ctx do
      id = insert!("tasks", task(ctx, %{}))

      assert %{rows: [["new", "medium", [], 1]]} =
               Repo.query!(
                 "SELECT status, priority, labels, lock_version FROM tasks WHERE id = $1",
                 [id]
               )
    end

    test "rejects an invalid status or priority", ctx do
      assert rejected("tasks", task(ctx, %{status: "open"})) == "tasks_status_check"
      assert rejected("tasks", task(ctx, %{priority: "urgent"})) == "tasks_priority_check"
    end

    test "rejects 21 labels", ctx do
      labels = for i <- 1..21, do: "l#{i}"
      assert rejected("tasks", task(ctx, %{labels: labels})) == "tasks_labels_count"
      assert insert!("tasks", task(ctx, %{labels: Enum.take(labels, 20)}))
    end

    test "rejects titles of 0 or 201 characters", ctx do
      for title <- ["", String.duplicate("t", 201)] do
        assert rejected("tasks", task(ctx, %{title: title})) == "tasks_title_length"
      end

      assert insert!("tasks", task(ctx, %{title: String.duplicate("t", 200)}))
    end

    test "rejects a description over 64 KB", ctx do
      assert rejected("tasks", task(ctx, %{description: String.duplicate("x", 65_537)})) ==
               "tasks_description_size"
    end

    test "numbers and IDs are unique", ctx do
      insert!("tasks", task(ctx, %{}))
      assert rejected("tasks", task(ctx, %{ident: "BOS-2"})) == "tasks_project_id_seq_index"
      assert rejected("tasks", task(ctx, %{seq: 2})) == "tasks_workspace_id_ident_index"
    end

    test "rejects a project of another workspace", ctx do
      assert rejected("tasks", task(ctx, %{project_id: ctx.other_project})) ==
               "tasks_project_id_fkey"
    end

    test "rejects a creator or assignee of another workspace", ctx do
      assert rejected("tasks", task(ctx, %{assignee_id: ctx.bob})) == "tasks_assignee_id_fkey"
      assert rejected("tasks", task(ctx, %{created_by_id: ctx.bob})) == "tasks_created_by_id_fkey"
    end
  end

  describe "task_events" do
    setup ctx, do: %{task: insert!("tasks", task(ctx, %{}))}

    defp event(ctx, attrs) do
      Map.merge(
        %{workspace_id: ctx.acme, task_id: ctx.task, to_status: "new", actor_id: ctx.alice},
        attrs
      )
    end

    test "accepts a creation entry", ctx do
      assert insert!("task_events", event(ctx, %{from_status: nil}))
    end

    test "rejects invalid statuses", ctx do
      assert rejected("task_events", event(ctx, %{to_status: "open"})) ==
               "task_events_status_check"

      assert rejected("task_events", event(ctx, %{from_status: "open"})) ==
               "task_events_status_check"
    end

    test "rejects an actor of another workspace", ctx do
      assert rejected("task_events", event(ctx, %{actor_id: ctx.bob})) ==
               "task_events_actor_id_fkey"
    end
  end
end
