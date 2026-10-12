defmodule Helmsman.Migrations.EpicsTest do
  # `add-epics` decision 2: the constraints the database enforces itself.
  use Helmsman.DataCase, async: true

  import Helmsman.AccountsFixtures
  import Helmsman.ProjectsFixtures
  import Helmsman.WorkspacesFixtures

  setup do
    owner = user_fixture()
    workspace = workspace_fixture(owner)
    scope = workspace_scope_fixture(owner, workspace)
    project_fixture(scope, key: "BOS")

    epic = task_fixture(scope, "BOS", kind: "epic")
    other_epic = task_fixture(scope, "BOS", kind: "epic")
    task = task_fixture(scope, "BOS")

    stranger = user_fixture()
    other_workspace = workspace_fixture(stranger)
    other_scope = workspace_scope_fixture(stranger, other_workspace)
    project_fixture(other_scope, key: "BOS")
    foreign = task_fixture(other_scope, "BOS")

    %{epic: epic, other_epic: other_epic, task: task, foreign: foreign}
  end

  defp violation(sql, params) do
    error =
      assert_raise Postgrex.Error, fn ->
        Repo.transaction(fn -> Repo.query!(sql, params) end)
      end

    {error.postgres.code, error.postgres.constraint}
  end

  test "kind is task by default and only task or epic", %{task: task} do
    assert %{rows: [["task"]]} = Repo.query!("SELECT kind FROM tasks WHERE id = $1", [task.id])

    assert {:check_violation, "tasks_kind_check"} =
             violation("UPDATE tasks SET kind = 'story' WHERE id = $1", [task.id])
  end

  test "an epic cannot belong to an epic", %{epic: epic, other_epic: other_epic} do
    assert {:check_violation, "tasks_epic_not_nested"} =
             violation("UPDATE tasks SET epic_id = $1 WHERE id = $2", [epic.id, other_epic.id])
  end

  test "a task cannot be its own epic", %{task: task} do
    assert {:check_violation, "tasks_epic_not_self"} =
             violation("UPDATE tasks SET epic_id = id WHERE id = $1", [task.id])
  end

  test "the epic is in the same workspace", %{epic: epic, foreign: foreign, task: task} do
    assert {:foreign_key_violation, "tasks_epic_id_fkey"} =
             violation("UPDATE tasks SET epic_id = $1 WHERE id = $2", [epic.id, foreign.id])

    Repo.query!("UPDATE tasks SET epic_id = $1 WHERE id = $2", [epic.id, task.id])
  end

  test "partial index on epic_id" do
    assert %{rows: [[definition]]} =
             Repo.query!(
               "SELECT indexdef FROM pg_indexes WHERE indexname = 'tasks_epic_id_index'",
               []
             )

    assert definition =~ "WHERE (epic_id IS NOT NULL)"
  end
end
