defmodule HelmsmanMCP.Tools.SearchTasksTest do
  # add-fulltext-search 1.9: `search_tasks` and the `query` of
  # `list_tasks` (decision 10).
  use Helmsman.DataCase, async: true

  import Helmsman.AccountsFixtures
  import Helmsman.ProjectsFixtures
  import Helmsman.WorkspacesFixtures
  import HelmsmanMCP.ToolHelpers

  alias Helmsman.{Feedback, Tasks}
  alias HelmsmanMCP.Tools

  setup do
    owner = user_fixture()
    workspace = workspace_fixture(owner)
    scope = workspace_scope_fixture(owner, workspace)
    project_fixture(scope, key: "BOS")
    project_fixture(scope, key: "KEEL")
    %{scope: scope, session: mcp_session(owner, workspace)}
  end

  test "the tool is listed with its description" do
    assert {:ok, tool} = Tools.fetch("search_tasks")
    assert tool.mode() == :read

    assert tool.description() ==
             "Full-text search over task IDs, labels, titles, descriptions and feedback, in " <>
               "Chinese and English. Best matches first; an exact task ID such as BOS-12 comes first."

    assert %{query: {:required, :string, _}, project_key: _, limit: _} = tool.input_schema()
  end

  describe "search_tasks" do
    test "检索: best first, snippets as text, empty keys left out", ctx do
      task_fixture(ctx.scope, "BOS", title: "Connection timeout")
      task_fixture(ctx.scope, "BOS", title: "Pool", description: "a timeout on start")
      task_fixture(ctx.scope, "BOS", title: "Startup")
      {:ok, _} = Feedback.add(ctx.scope, "BOS-3", %{content: "a timeout too", kind: "review"})
      ids = ~w(BOS-1 BOS-2 BOS-3)

      Repo.update_all(where(Helmsman.Tasks.Task, [t], t.ident in ^ids),
        set: [updated_at: ~U[2026-01-01 00:00:00Z]]
      )

      assert [first, second, third] = call!(ctx.session, "search_tasks", %{query: "timeout"})

      assert first == %{
               "id" => "BOS-1",
               "title" => "Connection timeout",
               "status" => "NEW",
               "project_key" => "BOS"
             }

      assert %{"id" => "BOS-2", "snippet" => "a **timeout** on start"} = second
      refute Map.has_key?(second, "feedback")

      assert %{
               "id" => "BOS-3",
               "feedback" => %{
                 "id" => "BOS-3#1",
                 "kind" => "review",
                 "author" => %{"kind" => "human"},
                 "snippet" => "a **timeout** too"
               }
             } = third

      refute Map.has_key?(third, "snippet")
    end

    test "the assignee is shown when there is one", ctx do
      {:ok, _} = Tasks.create(ctx.scope, "BOS", %{title: "mine", assignee: ctx.scope.actor.name})

      assert [%{"assignee" => %{"name" => name, "kind" => "human"}}] =
               call!(ctx.session, "search_tasks", %{query: "mine"})

      assert name == ctx.scope.actor.name
    end

    test "an exact ID comes first; project and limit", ctx do
      task_fixture(ctx.scope, "BOS", title: "first")
      task_fixture(ctx.scope, "KEEL", title: "about bos-1 bos-1")

      assert [%{"id" => "BOS-1"}, %{"id" => "KEEL-1"}] =
               call!(ctx.session, "search_tasks", %{query: "bos-1"})

      assert [%{"id" => "KEEL-1"}] =
               call!(ctx.session, "search_tasks", %{query: "about", project_key: "KEEL"})

      assert [_] = call!(ctx.session, "search_tasks", %{query: "bos-1", limit: 1})
    end

    test "an empty query is an empty list", ctx do
      task_fixture(ctx.scope, "BOS", title: "x")
      assert call!(ctx.session, "search_tasks", %{query: "  "}) == []
    end

    test "查询过长", ctx do
      assert {:error, "The query is too long (at most 200 characters)."} =
               call(ctx.session, "search_tasks", %{query: String.duplicate("x", 300)})
    end

    test "an unknown project", ctx do
      assert {:error, text} =
               call(ctx.session, "search_tasks", %{query: "x", project_key: "NOPE"})

      assert text =~ "Project NOPE not found"
    end
  end

  describe "list_tasks query" do
    test "list_tasks 带 query: with the status, by update", ctx do
      a = task_fixture(ctx.scope, "BOS", title: "登录超时")
      task_fixture(ctx.scope, "BOS", title: "无关")
      b = task_fixture(ctx.scope, "BOS", title: "x", description: "登录失败")
      started = task_fixture(ctx.scope, "BOS", title: "登录")
      {:ok, _} = Tasks.transition(ctx.scope, started.ident, :in_progress)

      assert [%{"id" => id_b}, %{"id" => id_a}] =
               call!(ctx.session, "list_tasks", %{project_key: "BOS", query: "登录", status: "NEW"})

      assert {id_a, id_b} == {a.ident, b.ident}
    end

    test "the description of the argument", _ctx do
      {:ok, tool} = Tools.fetch("list_tasks")

      assert {:string,
              description:
                "Only tasks whose ID, labels, title, description or feedback match this text."} =
               tool.input_schema().query
    end

    test "too long", ctx do
      assert {:error, "The query is too long (at most 200 characters)."} =
               call(ctx.session, "list_tasks", %{
                 project_key: "BOS",
                 query: String.duplicate("x", 300)
               })
    end
  end
end
