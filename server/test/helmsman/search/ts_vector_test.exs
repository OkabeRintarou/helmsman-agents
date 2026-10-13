defmodule Helmsman.Search.TsVectorTest do
  # add-fulltext-search 1.1: the search columns and their Ecto type
  # (decision 2).
  use Helmsman.DataCase, async: true

  import Helmsman.AccountsFixtures
  import Helmsman.ProjectsFixtures
  import Helmsman.WorkspacesFixtures

  alias Helmsman.QueryCount
  alias Helmsman.Search.TsVector
  alias Helmsman.Tasks.Task

  setup do
    owner = user_fixture()
    workspace = workspace_fixture(owner)
    scope = workspace_scope_fixture(owner, workspace)
    project = project_fixture(scope, key: "BOS")
    %{scope: scope, task: task_fixture(scope, project.key, title: "Search")}
  end

  test "lexemes are written in the binary protocol and read back as text", %{task: task} do
    lexemes = [
      %Postgrex.Lexeme{word: "bos-1", positions: [{1, :A}]},
      %Postgrex.Lexeme{word: "it's", positions: [{2, :B}, {5, :C}]},
      %Postgrex.Lexeme{word: "a\\b", positions: []}
    ]

    {1, _} = Repo.update_all(where(Task, id: ^task.id), set: [search: lexemes])

    assert %{rows: [[text]]} =
             Repo.query!("SELECT search::text FROM tasks WHERE id = $1", [task.id])

    assert text == ~S('a\\b' 'bos-1':1A 'it''s':2B,5C)

    assert Repo.one!(from(t in Task, where: t.id == ^task.id, select: t.search)) == [
             %Postgrex.Lexeme{word: "a\\b", positions: []},
             %Postgrex.Lexeme{word: "bos-1", positions: [{1, :A}]},
             %Postgrex.Lexeme{word: "it's", positions: [{2, :B}, {5, :C}]}
           ]
  end

  test "the type accepts lexeme lists and nil only" do
    assert TsVector.type() == :tsvector
    assert {:ok, nil} = TsVector.dump(nil)
    assert {:ok, []} = TsVector.cast([])
    assert :error = TsVector.cast("'a'")
    assert :error = TsVector.dump([%{word: "a"}])
  end

  test "plain reads never select the column", %{task: task} do
    parent = self()
    handler = "search-sql-#{System.unique_integer()}"

    :telemetry.attach(
      handler,
      [:helmsman, :repo, :query],
      fn _event, _measurements, meta, _config ->
        if self() == parent, do: send(parent, {:sql, meta.query})
      end,
      nil
    )

    try do
      {loaded, 1} = QueryCount.count(fn -> Repo.get(Task, task.id) end)
      assert loaded.search == nil
      assert_received {:sql, sql}
      assert sql =~ "FROM \"tasks\""
      refute sql =~ "search"
    after
      :telemetry.detach(handler)
    end
  end
end
