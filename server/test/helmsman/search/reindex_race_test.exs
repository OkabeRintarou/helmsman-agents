defmodule Helmsman.Search.ReindexRaceTest do
  # add-fulltext-search 1.8, 并发编辑: a title edit committed on another
  # connection between the rebuild's read and its write wins; the rebuild
  # never waits for it nor overwrites it. Committed data outside the
  # sandbox.
  use ExUnit.Case, async: false

  import Ecto.Query
  import Helmsman.AccountsFixtures
  import Helmsman.ProjectsFixtures
  import Helmsman.WorkspacesFixtures

  alias Helmsman.{CommittedData, Repo, Search, Tasks}
  alias Helmsman.Search.Reindex
  alias Helmsman.Tasks.Task, as: TaskRow

  setup do
    tag = System.unique_integer([:positive])

    {owner, workspace, scope} =
      CommittedData.unboxed(fn ->
        owner = user_fixture(%{email: "owner-#{tag}@reindex.test"})
        workspace = workspace_fixture(owner)
        scope = workspace_scope_fixture(owner, workspace)
        project_fixture(scope, key: "BOS")
        {owner, workspace, scope}
      end)

    on_exit(fn -> CommittedData.delete_user_data!([owner.id]) end)
    %{workspace: workspace, scope: scope}
  end

  test "an edit committed between read and write is kept", %{workspace: workspace, scope: scope} do
    task =
      CommittedData.unboxed(fn ->
        task = task_fixture(scope, "BOS", title: "quokka")
        Repo.update_all(where(TaskRow, id: ^task.id), set: [search: nil])
        task
      end)

    Process.put(:helmsman_test_hook, fn
      {:task_read, id} when id == task.id ->
        Process.delete(:helmsman_test_hook)

        edit =
          Task.async(fn ->
            CommittedData.unboxed(fn -> Tasks.update(scope, task.ident, %{title: "wombat"}) end)
          end)

        assert {:ok, _} = Task.await(edit)

      _point ->
        :ok
    end)

    counts = CommittedData.unboxed(fn -> Reindex.run(workspace: workspace.slug) end)
    assert counts == %{tasks: 0, feedback: 0, cleared: 0, skipped: 1}

    CommittedData.unboxed(fn ->
      assert {:ok, [%{task: %{id: "BOS-1"}}]} = Search.search(scope, "wombat")
      assert {:ok, []} = Search.search(scope, "quokka")
    end)
  end
end
