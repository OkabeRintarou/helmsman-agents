defmodule Helmsman.Search.ReindexTest do
  # add-fulltext-search 1.8: rebuilding the search columns (decision 9).
  use Helmsman.DataCase, async: true

  import Helmsman.AccountsFixtures
  import Helmsman.ProjectsFixtures
  import Helmsman.WorkspacesFixtures

  alias Helmsman.{Feedback, Search, Tasks}
  alias Helmsman.Feedback.Entry
  alias Helmsman.Search.Reindex
  alias Helmsman.Tasks.Task

  setup do
    owner = user_fixture()
    workspace = workspace_fixture(owner)
    scope = workspace_scope_fixture(owner, workspace)
    project_fixture(scope, key: "BOS")
    %{scope: scope, workspace: workspace}
  end

  defp ids(scope, query) do
    {:ok, hits} = Search.search(scope, query)
    Enum.map(hits, & &1.task.id)
  end

  # The data as it was before this capability: no search columns.
  defp forget(workspace) do
    Repo.update_all(where(Task, workspace_id: ^workspace.id), set: [search: nil])
    Repo.update_all(where(Entry, workspace_id: ^workspace.id), set: [search: nil])
  end

  defp run(workspace), do: Reindex.run(workspace: workspace.slug)

  test "补齐已有数据", %{scope: scope, workspace: workspace} do
    for n <- 1..3 do
      task = task_fixture(scope, "BOS", title: "quokka #{n}")
      {:ok, _} = Feedback.add(scope, task.ident, %{content: "wombat #{n}"})
    end

    {:ok, _} = Feedback.add(scope, "BOS-1", %{content: "wombat again"})
    {:ok, _} = Feedback.add(scope, "BOS-2", %{content: "wombat more"})
    forget(workspace)
    assert ids(scope, "quokka") == []
    assert ids(scope, "wombat") == []

    assert run(workspace) == %{tasks: 3, feedback: 5, cleared: 0, skipped: 0}
    assert length(ids(scope, "quokka")) == 3
    assert length(ids(scope, "wombat")) == 3
  end

  test "重复运行: the same results", %{scope: scope, workspace: workspace} do
    task_fixture(scope, "BOS", title: "quokka", description: "任务管理")
    first = Repo.all(from(t in Task, select: t.search))
    run(workspace)
    hits = Search.search(scope, "任务管理")
    run(workspace)
    assert Search.search(scope, "任务管理") == hits
    assert Repo.all(from(t in Task, select: t.search)) == first
  end

  test "并发编辑: the new title wins", %{scope: scope, workspace: workspace} do
    task = task_fixture(scope, "BOS", title: "quokka")
    forget(workspace)

    Process.put(:helmsman_test_hook, fn
      {:task_read, id} when id == task.id ->
        Process.delete(:helmsman_test_hook)
        {:ok, _} = Tasks.update(scope, task.ident, %{title: "wombat"})

      _point ->
        :ok
    end)

    assert %{tasks: 0, skipped: 1} = run(workspace)
    assert ids(scope, "wombat") == [task.ident]
    assert ids(scope, "quokka") == []
  end

  test "superseded records are cleared and counted", %{scope: scope, workspace: workspace} do
    task = task_fixture(scope, "BOS", title: "x")
    {:ok, old} = Feedback.add(scope, task.ident, %{content: "deadlock"})
    {:ok, _} = Feedback.revise(scope, "BOS-1#1", %{content: "fine"})
    # As written before this capability: the old record still indexed.
    Repo.update_all(where(Entry, id: ^old.id),
      set: [search: [%Postgrex.Lexeme{word: "deadlock", positions: [{1, :C}]}]]
    )

    assert %{cleared: 1, feedback: 1, tasks: 1} = run(workspace)
    assert ids(scope, "deadlock") == []
    assert %{cleared: 0} = run(workspace)
  end

  test "--workspace only touches that workspace", %{scope: scope, workspace: workspace} do
    task_fixture(scope, "BOS", title: "quokka")
    other_owner = user_fixture()
    other_ws = workspace_fixture(other_owner)
    other = workspace_scope_fixture(other_owner, other_ws)
    project_fixture(other, key: "BOS")
    task_fixture(other, "BOS", title: "quokka")
    forget(workspace)
    forget(other_ws)

    assert %{tasks: 1} = run(workspace)
    assert ids(scope, "quokka") == ["BOS-1"]
    assert ids(other, "quokka") == []
  end

  test "small batches cover every row", %{scope: scope, workspace: workspace} do
    for _ <- 1..5, do: task_fixture(scope, "BOS", title: "quokka")
    forget(workspace)
    assert %{tasks: 5} = Reindex.run(workspace: workspace.slug, batch: 2)
    assert length(ids(scope, "quokka")) == 5
  end

  test "an unknown workspace is an error" do
    assert_raise ArgumentError, ~r/no workspace/, fn -> Reindex.run(workspace: "nope-x") end
  end
end
