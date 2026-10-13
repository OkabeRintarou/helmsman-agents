defmodule HelmsmanMCP.Tools.QueryTasksTest do
  use Helmsman.DataCase, async: false
  import Helmsman.BQLFixtures
  import HelmsmanMCP.ToolHelpers
  import Helmsman.RunsFixtures, only: [dispatch_fixture: 0, run_fixture: 2, run_scope_fixture: 1]
  import Helmsman.ProjectsFixtures
  alias Helmsman.{Filters, Tasks}
  alias HelmsmanMCP.Pipeline

  setup do
    ctx = bql_fixture()
    Map.put(ctx, :session, mcp_session(ctx.user, ctx.workspace))
  end

  test "large nonnegative integer comparisons stay ordinary MCP query results", ctx do
    for bound <- [2_147_483_647, 2_147_483_648, String.duplicate("9", 500)],
        {op, total} <- [{"=", 0}, {"!=", 5}, {">", 0}, {">=", 0}, {"<", 5}, {"<=", 5}] do
      result = call!(ctx.session, "query_tasks", %{bql: "feedback_count #{op} #{bound}"})
      assert result["total"] == total
    end
  end

  test "ordinary queries, summaries, paging and exact errors", ctx do
    result = call!(ctx.session, "query_tasks", %{bql: "project = BQ AND status = NEW", limit: 1})
    assert result["total"] == 2 and length(result["tasks"]) == 1
    assert result["order"] == [%{"field" => "updated", "dir" => "desc"}]
    assert result["text"] =~ "2 total; 1 tasks on this page"
    [task] = result["tasks"]

    assert task["status"] == "NEW" and Map.has_key?(task, "created_at") and
             Map.has_key?(task, "blocked")

    assert call!(ctx.session, "query_tasks", %{bql: "text ~ backend"})["order"] == "relevance"

    for args <- [%{}, %{bql: "status = new", filter_id: 3}],
        do:
          assert(
            call(ctx.session, "query_tasks", args) == {:error, "Pass either bql or filter_id."}
          )

    assert {:error, text} = call(ctx.session, "query_tasks", %{bql: "stauts = new"})

    assert String.starts_with?(
             text,
             "Invalid BQL at position 1: unknown field 'stauts' Available fields:"
           )

    assert text =~ "assignee_kind" and text =~ "owner"

    assert {:error, "Invalid BQL at position 14: expected ')'"} =
             call(ctx.session, "query_tasks", %{bql: "(status = new"})

    assert {:error, "Invalid limit; use limit 1–200 and offset 0–10000."} =
             call(ctx.session, "query_tasks", %{bql: "", limit: 0})
  end

  test "no default Agent needs identify only for currentUser including a shared saved query",
       ctx do
    assert {:ok, f} =
             Filters.create(ctx.scope, %{
               name: "self",
               bql: "assignee IN (currentUser())",
               visibility: :workspace
             })

    for args <- [
          %{bql: "assignee = currentUser()"},
          %{bql: "created_by IN (currentUser())"},
          %{bql: "owner NOT IN (currentUser())"},
          %{filter_id: "#{f.id}"}
        ],
        do:
          assert(
            call(ctx.session, "query_tasks", args) ==
              {:error, "currentUser() needs an identity; call identify first."}
          )

    assert call!(ctx.session, "query_tasks", %{bql: "status = new"})["total"] == 4
    call!(ctx.session, "identify", %{name: "claude-desktop"})

    assert {:ok, _} =
             Tasks.update(ctx.scope, ctx.bq1.ident, %{assignee: "claude-desktop", start: false})

    assert [%{"id" => "BQ-1"}] =
             call!(ctx.session, "query_tasks", %{bql: "assignee = currentUser()"})["tasks"]

    assert [%{"id" => "BQ-1"}] = call!(ctx.session, "query_tasks", %{filter_id: f.id})["tasks"]
  end

  test "run token uses its managed identity and shared query only" do
    ctx = dispatch_fixture()
    task = task_fixture(ctx.alice_scope, ctx.project.key, assignee: ctx.agent.name, start: false)
    run = run_fixture(ctx.agent, %{task_id: task.id, status: :running})
    {scope, _} = run_scope_fixture(run)

    assert {:ok, json} =
             Pipeline.call_tool("query_tasks", %{bql: "assignee = currentUser()"}, scope, nil)

    assert [%{"id" => id}] = Jason.decode!(json)["tasks"]
    assert id == task.ident

    assert {:ok, shared} =
             Filters.create(ctx.alice_scope, %{
               name: "shared",
               bql: "owner = currentUser()",
               visibility: :workspace
             })

    assert {:ok, private} = Filters.create(ctx.alice_scope, %{name: "private", bql: ""})

    assert {:ok, json} =
             Pipeline.call_tool("query_tasks", %{filter_id: "#{shared.id}"}, scope, nil)

    assert Jason.decode!(json)["total"] == 1

    assert {:error, text} =
             Pipeline.call_tool("query_tasks", %{filter_id: private.id}, scope, nil)

    assert text =~ "Not found"
  end

  test "query timeout has actionable text and does not poison later MCP calls", ctx do
    old = Application.get_env(:helmsman, Helmsman.BQL)

    on_exit(fn ->
      if old,
        do: Application.put_env(:helmsman, Helmsman.BQL, old),
        else: Application.delete_env(:helmsman, Helmsman.BQL)
    end)

    Application.put_env(:helmsman, Helmsman.BQL, statement_timeout_ms: 1)
    Process.put(:helmsman_bql_query_hook, fn -> Helmsman.Repo.query!("SELECT pg_sleep(0.02)") end)

    assert {:error, "The query took too long; narrow it down (e.g. add project = KEY)."} =
             call(ctx.session, "query_tasks", %{bql: ""})

    Process.delete(:helmsman_bql_query_hook)
    Application.delete_env(:helmsman, Helmsman.BQL)
    assert call!(ctx.session, "query_tasks", %{bql: "status = new"})["total"] == 4
  end
end
