defmodule Helmsman.Tasks.ListQueryTest do
  # add-fulltext-search 1.7: the text filter of the task list (decision 8).
  use Helmsman.DataCase, async: true

  import Helmsman.AccountsFixtures
  import Helmsman.ProjectsFixtures
  import Helmsman.WorkspacesFixtures

  alias Helmsman.{Feedback, Tasks}

  setup do
    owner = user_fixture()
    workspace = workspace_fixture(owner)
    scope = workspace_scope_fixture(owner, workspace)
    project_fixture(scope, key: "BOS")
    %{scope: scope}
  end

  defp ids(scope, opts) do
    {:ok, tasks} = Tasks.list(scope, "BOS", opts)
    Enum.map(tasks, & &1.ident)
  end

  test "与状态同时筛选: both conditions, most recently updated first", %{scope: scope} do
    a = task_fixture(scope, "BOS", title: "登录超时")
    started = task_fixture(scope, "BOS", title: "登录失败")
    {:ok, _} = Tasks.transition(scope, started.ident, :in_progress)
    task_fixture(scope, "BOS", title: "无关")
    b = task_fixture(scope, "BOS", title: "x", description: "修复登录")

    assert ids(scope, q: "登录", status: "new") == [b.ident, a.ident]
    assert ids(scope, q: "登录") == [b.ident, started.ident, a.ident]
  end

  test "the order is by update, not by rank", %{scope: scope} do
    title = task_fixture(scope, "BOS", title: "deadlock")
    desc = task_fixture(scope, "BOS", title: "x", description: "deadlock")
    assert ids(scope, q: "deadlock") == [desc.ident, title.ident]
  end

  test "Feedback 命中", %{scope: scope} do
    task_fixture(scope, "BOS", title: "a")
    task_fixture(scope, "BOS", title: "b")
    bos3 = task_fixture(scope, "BOS", title: "c")
    {:ok, _} = Feedback.add(scope, bos3.ident, %{content: "found a deadlock"})
    assert ids(scope, q: "deadlock") == ["BOS-3"]

    {:ok, _} = Feedback.revise(scope, "BOS-3#1", %{content: "fine"})
    assert ids(scope, q: "deadlock") == []
  end

  test "空白条件: ignored", %{scope: scope} do
    for _ <- 1..3, do: task_fixture(scope, "BOS")
    assert ids(scope, q: "  ") == ids(scope, [])
    assert length(ids(scope, q: "  ")) == 3
  end

  test "nothing to search for matches nothing", %{scope: scope} do
    task_fixture(scope, "BOS", title: "the")
    assert ids(scope, q: "the") == []
  end

  test "too long or not a string", %{scope: scope} do
    assert {:error, {:invalid_query, :too_long}} =
             Tasks.list(scope, "BOS", q: String.duplicate("x", 201))

    assert {:error, {:invalid_query, :not_a_string}} = Tasks.list(scope, "BOS", q: 1)
  end

  test "with keyset pages and limits", %{scope: scope} do
    for n <- 1..5, do: task_fixture(scope, "BOS", title: "match #{n}")
    task_fixture(scope, "BOS", title: "other")
    {:ok, [_, _] = first} = Tasks.list(scope, "BOS", q: "match", limit: 2)
    last = List.last(first)

    {:ok, second} =
      Tasks.list(scope, "BOS", q: "match", limit: 2, before: {last.updated_at, last.id})

    {:ok, third} = Tasks.list(scope, "BOS", q: "match", limit: 2, offset: 4)

    assert Enum.map(first ++ second, & &1.ident) == ["BOS-5", "BOS-4", "BOS-3", "BOS-2"]
    assert Enum.map(third, & &1.ident) == ["BOS-1"]
  end

  test "with label and assignee filters", %{scope: scope} do
    task_fixture(scope, "BOS", title: "match", labels: ["ui"])
    task_fixture(scope, "BOS", title: "match")
    assert ids(scope, q: "match", label: "ui") == ["BOS-1"]
    assert ids(scope, q: "match", assignee: "") == ["BOS-2", "BOS-1"]
  end
end
