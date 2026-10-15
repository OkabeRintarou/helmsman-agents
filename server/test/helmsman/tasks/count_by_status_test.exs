defmodule Helmsman.Tasks.CountByStatusTest do
  use Helmsman.DataCase, async: true
  import Helmsman.RunsFixtures
  import Helmsman.ProjectsFixtures
  alias Helmsman.{QueryCount, Tasks}

  setup do
    ctx = dispatch_fixture()
    {_user, viewer} = member_scope_fixture(ctx.workspace, :viewer)
    Map.put(ctx, :viewer, viewer)
  end

  test "six states, all shared filters, unassigned, epic and empty project in one query", ctx do
    scope = ctx.alice_scope
    task_fixture(scope, ctx.project.key, %{title: "Board needle", labels: ["ui"], kind: "epic"})

    task =
      task_fixture(scope, ctx.project.key, %{
        title: "Other",
        labels: ["ui"],
        assignee: scope.actor.name
      })

    {:ok, _} = Tasks.transition(scope, task.ident, "in_progress", %{})

    assert {{:ok, counts}, 1} =
             QueryCount.count(fn ->
               Tasks.count_by_status(ctx.viewer, ctx.project.key, status: "done", limit: 1)
             end)

    assert counts == %{
             "new" => 1,
             "in_progress" => 1,
             "done" => 0,
             "verified" => 0,
             "rejected" => 0,
             "cancelled" => 0
           }

    for opts <- [
          [assignee: ""],
          [q: "needle"],
          [kind: "epic"],
          [label: "ui", assignee: "", kind: "epic"]
        ] do
      assert {{:ok, %{"new" => 1, "in_progress" => 0}}, 1} =
               QueryCount.count(fn ->
                 Tasks.count_by_status(ctx.viewer, ctx.project.key, opts)
               end)
    end

    assert {:ok, %{"new" => 0}} =
             Tasks.count_by_status(ctx.viewer, ctx.project.key, label: "missing")

    empty = project_fixture(scope)
    assert {:ok, counts} = Tasks.count_by_status(ctx.viewer, empty.key)
    assert Enum.all?(counts, fn {_s, n} -> n == 0 end)
    assert {:error, :not_found} = Tasks.count_by_status(ctx.viewer, "NOPE")

    assert {:error, :forbidden} =
             Tasks.count_by_status(%{ctx.viewer | role: nil}, ctx.project.key)

    assert {:error, {:invalid_query, _}} =
             Tasks.count_by_status(ctx.viewer, ctx.project.key, q: String.duplicate("a", 201))
  end

  test "1000 tasks use the project/status keyset index", ctx do
    now = DateTime.utc_now()

    rows =
      for n <- 1..1000,
          do: %{
            workspace_id: ctx.workspace.id,
            project_id: ctx.project.id,
            seq: n,
            ident: "#{ctx.project.key}-#{n}",
            title: "Scale",
            description: "",
            status: :new,
            priority: :medium,
            kind: :task,
            labels: [],
            created_by_id: ctx.alice_scope.actor.id,
            inserted_at: now,
            updated_at: now
          }

    Helmsman.Repo.insert_all(Helmsman.Tasks.Task, rows)

    %{rows: plan} =
      Helmsman.Repo.query!(
        "EXPLAIN SELECT id FROM tasks WHERE project_id = $1 AND status = 'new' ORDER BY updated_at DESC, id DESC LIMIT 26",
        [ctx.project.id]
      )

    assert Enum.map_join(plan, "\n", &hd/1) =~ "tasks_project_id_status_updated_at_id_index"
    other = dispatch_fixture()
    assert {:error, :not_found} = Tasks.count_by_status(other.alice_scope, ctx.project.key)
  end
end
