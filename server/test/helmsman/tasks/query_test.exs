defmodule Helmsman.Tasks.QueryTest do
  use Helmsman.DataCase, async: false
  import Helmsman.BQLFixtures
  import Helmsman.AccountsFixtures
  import Helmsman.ProjectsFixtures
  import Helmsman.WorkspacesFixtures
  import Helmsman.RunsFixtures, only: [dispatch_fixture: 0, run_fixture: 2, run_scope_fixture: 1]
  alias Helmsman.{BQL, Filters, Repo, Tasks}

  test "integer comparisons include int4 boundaries and arbitrary precision", ctx do
    max = 2_147_483_647
    Repo.update_all(Helmsman.Tasks.Task, set: [feedback_count: 0])

    Repo.update_all(Ecto.Query.from(t in Helmsman.Tasks.Task, where: t.id == ^ctx.bq1.id),
      set: [feedback_count: max]
    )

    for bound <- [max, max + 1, String.to_integer(String.duplicate("9", 500))],
        {op, totals} <- [
          {"=", {1, 0}},
          {"!=", {4, 5}},
          {">", {0, 0}},
          {">=", {1, 0}},
          {"<", {4, 5}},
          {"<=", {5, 5}}
        ] do
      expected = elem(totals, if(bound == max, do: 0, else: 1))
      query = "feedback_count #{op} #{bound}"
      assert {:ok, ast} = BQL.parse(query)
      assert {:ok, %{total: ^expected}} = Tasks.query(ctx.scope, query)
      assert {:ok, %{total: ^expected}} = Tasks.query(ctx.scope, ast)
    end
  end

  test "parsed AST and string queries agree at nesting and length boundaries", ctx do
    queries = for n <- [1, 16, 17, 32], do: String.duplicate("NOT ", n) <> "status = new"

    queries =
      queries ++
        [
          String.duplicate("NOT ", 30) <> "(status = new OR priority = low)",
          "NOT (status = new AND (priority = high OR (labels = mcp AND question = true)))",
          "title = " <> String.duplicate("x", 1992)
        ]

    for query <- queries do
      assert {:ok, ast} = BQL.parse(query)
      assert {:ok, result} = Tasks.query(ctx.scope, query)
      assert {:ok, ^result} = Tasks.query(ctx.scope, ast)
      assert {:ok, ^ast} = BQL.parse(BQL.to_string(ast))
    end

    # Canonical field names can be longer than source aliases. AST execution
    # must retain a valid original query even when its displayed text grows.
    query = "reporter=" <> String.duplicate("x", 1991)
    assert {:ok, ast} = BQL.parse(query)
    assert length(String.codepoints(BQL.to_string(ast))) > 2000

    assert {:error, {:invalid_bql, %{message: "query is too long"}}} =
             BQL.parse(BQL.to_string(ast))

    assert {:ok, result} = Tasks.query(ctx.scope, query)
    assert {:ok, ^result} = Tasks.query(ctx.scope, ast)
  end

  test "Unicode lowercase expansion preserves string and AST query results", ctx do
    query = "labels=" <> String.duplicate("İ", 1990)
    assert {:ok, %{where: {:cond, :labels, :eq, value}} = ast} = BQL.parse(query)
    assert length(String.codepoints(value)) == 3980
    assert {:ok, ^ast} = BQL.validate_ast(ast)
    assert {:ok, result} = Tasks.query(ctx.scope, query)
    assert {:ok, ^result} = Tasks.query(ctx.scope, ast)
  end

  setup do
    bql_fixture()
  end

  test "stable pagination, natural order and validation", ctx do
    assert {:ok, %{tasks: all, total: 5}} = Tasks.query(ctx.scope, "ORDER BY id", limit: 200)
    assert Enum.map(all, & &1.id) == ~w(BQ-1 BQ-2 BQ-3 OT-1 OT-2)

    pages =
      for offset <- [0, 2, 4] do
        assert {:ok, %{tasks: page, total: 5}} =
                 Tasks.query(ctx.scope, "ORDER BY id", limit: 2, offset: offset)

        page
      end

    assert List.flatten(pages) == all

    for {key, values} <- [limit: [0, 201, "2", nil], offset: [-1, 10_001, "0", nil]],
        value <- values,
        do: assert({:error, {:invalid, ^key}} = Tasks.query(ctx.scope, "", [{key, value}]))

    for q <- [
          "",
          "ORDER BY priority",
          "ORDER BY status",
          "ORDER BY title",
          "ORDER BY assignee DESC",
          "ORDER BY created_by",
          "ORDER BY feedback_count",
          "ORDER BY question",
          "ORDER BY kind",
          "ORDER BY run",
          "ORDER BY pr"
        ],
        do: assert({:ok, %{total: 5}} = Tasks.query(ctx.scope, q))

    for dir <- ["ASC", "DESC"] do
      assert {:ok, %{tasks: [first | rest]}} = Tasks.query(ctx.scope, "ORDER BY assignee #{dir}")
      assert first.id == "BQ-2"
      assert length(rest) == 4
    end

    assert {:ok, %{order: :relevance}} =
             Tasks.query(ctx.scope, "text ~ backend OR feedback ~ port")

    assert {:ok, %{order: [{:updated, :desc}]}} = Tasks.query(ctx.scope, "NOT text ~ backend")
    assert {:ok, %{order: [{:id, :asc}]}} = Tasks.query(ctx.scope, "text ~ backend ORDER BY id")
  end

  test "workspace isolation, viewers and no-role scopes", ctx do
    other_user = user_fixture()
    other = workspace_fixture(other_user)
    other_scope = workspace_scope_fixture(other_user, other)
    project_fixture(other_scope, key: "OTHER")
    task_fixture(other_scope, "OTHER")
    assert {:ok, %{tasks: [], total: 0}} = Tasks.query(ctx.scope, "project = OTHER")
    assert {:ok, %{total: 5}} = Tasks.query(%{ctx.scope | role: :viewer}, "")
    assert {:error, :forbidden} = Tasks.query(%{ctx.scope | role: nil}, "")
  end

  test "current human and symbolic filter execution; missing identity never compares NULL", ctx do
    assert {:ok, %{tasks: [%{id: "BQ-2"}]}} = Tasks.query(ctx.scope, "assignee = currentUser()")

    assert {:ok, f} =
             Filters.create(ctx.scope, %{
               name: "self",
               bql: "owner NOT IN (currentUser())",
               visibility: :workspace
             })

    for q <- [
          "assignee = currentUser()",
          "assignee IN (currentUser())",
          "owner NOT IN (currentUser())",
          f
        ],
        do: assert({:error, :no_identity} = Tasks.query(%{ctx.scope | actor: nil}, q))

    assert {:ok, %{total: 4}} = Tasks.query(%{ctx.scope | actor: nil}, "status = new")
  end

  test "managed run identity has read capability", _ctx do
    ctx = dispatch_fixture()
    task = task_fixture(ctx.alice_scope, ctx.project.key, assignee: ctx.agent.name, start: false)
    run = run_fixture(ctx.agent, %{task_id: task.id, status: :running})
    {scope, _} = run_scope_fixture(run)
    assert {:ok, %{tasks: [%{id: id}]}} = Tasks.query(scope, "assignee = currentUser()")
    assert id == task.ident
    assert {:ok, %{total: 1}} = Tasks.query(scope, "owner = currentUser()")
    assert {:error, :forbidden} = Tasks.query(%{scope | run: %{run | capabilities: []}}, "")
  end

  test "timeout is local and a cancelled statement does not poison the caller transaction", ctx do
    old = Application.get_env(:helmsman, Helmsman.BQL)

    on_exit(fn ->
      if old,
        do: Application.put_env(:helmsman, Helmsman.BQL, old),
        else: Application.delete_env(:helmsman, Helmsman.BQL)
    end)

    Application.put_env(:helmsman, Helmsman.BQL, statement_timeout_ms: 1)
    Process.put(:helmsman_bql_query_hook, fn -> Repo.query!("SELECT pg_sleep(0.02)") end)
    assert {:error, :query_timeout} = Tasks.query(ctx.scope, "")
    Process.delete(:helmsman_bql_query_hook)
    Application.delete_env(:helmsman, Helmsman.BQL)
    assert {:ok, %{total: 5}} = Tasks.query(ctx.scope, "")
    assert %{rows: [["0"]]} = Repo.query!("SHOW statement_timeout")
  end
end
