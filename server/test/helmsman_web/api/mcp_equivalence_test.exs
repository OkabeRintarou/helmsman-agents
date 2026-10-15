defmodule HelmsmanWeb.API.MCPEquivalenceTest do
  # add-rest-api 2.3 / decision 14: the same token through MCP
  # (HelmsmanMCP.Pipeline.call_tool/4) and REST gets the same JSON.
  use HelmsmanWeb.ConnCase, async: true

  import Helmsman.AgentsFixtures
  import Helmsman.ApiTokensFixtures
  import Helmsman.LinksFixtures, only: [set_status!: 2]
  import Helmsman.ProjectsFixtures
  import HelmsmanWeb.APIHelpers

  alias HelmsmanMCP.{Pipeline, Sessions}

  setup do
    ctx = api_fixture()
    keel = agent_fixture(ctx.workspace, ctx.alice, "keel/dev")
    managed_agent_fixture(ctx.scope, %{name: "keel/run", access: "workspace"})

    %{token: token, api_token: api_token} =
      api_token_fixture(ctx.scope, %{default_agent_id: keel.id})

    project_fixture(ctx.scope, %{key: "BOS"})

    # Pairs of identical tasks: one for MCP (odd), one for REST (even).
    for title <- ["One", "One", "Two", "Two"], do: task_fixture(ctx.scope, "BOS", %{title: title})

    mcp_scope = token_scope_fixture(ctx.alice, ctx.workspace, :mcp, api_token)
    sid = "rest-eq-#{System.unique_integer([:positive])}"
    :ok = Sessions.register(sid, mcp_scope, self())

    Map.merge(ctx, %{token: token, mcp: {mcp_scope, sid}})
  end

  defp mcp(%{mcp: {scope, sid}}, tool, args) do
    {:ok, json} = Pipeline.call_tool(tool, args, scope, sid)
    Jason.decode!(json)
  end

  defp rest(conn, status), do: conn |> body!(status) |> Map.fetch!("data")

  # Times and the IDs of the task pairs differ between the two results.
  defp normalize(value, ids) do
    case value do
      map when is_map(map) -> Map.new(map, fn {k, v} -> {k, normalize(v, ids)} end)
      list when is_list(list) -> Enum.map(list, &normalize(&1, ids))
      text when is_binary(text) -> normalize_text(text, ids)
      other -> other
    end
  end

  defp normalize_text(text, ids) do
    if text =~ ~r/\A\d{4}-\d\d-\d\dT/ do
      "<time>"
    else
      Regex.replace(~r/\bBOS-\d+\b/, text, fn ident -> Map.get(ids, ident, ident) end)
    end
  end

  test "get_task", ctx do
    assert rest(api_get(ctx.token, w(ctx.slug, "/tasks/BOS-1")), 200) ==
             mcp(ctx, "get_task", %{"task_id" => "BOS-1"})
  end

  test "list_tasks with a status list and a limit", ctx do
    set_status!(
      %{id: Helmsman.Repo.get_by!(Helmsman.Tasks.Task, ident: "BOS-2").id},
      :in_progress
    )

    assert rest(
             api_get(
               ctx.token,
               w(ctx.slug, "/projects/BOS/tasks?status=NEW,IN_PROGRESS&limit=3")
             ),
             200
           ) ==
             mcp(ctx, "list_tasks", %{
               "project_key" => "BOS",
               "status" => ["NEW", "IN_PROGRESS"],
               "limit" => 3
             })
  end

  test "create_task with an assignee, and its dispatch", ctx do
    args = %{"title" => "New", "assignee" => "keel/run", "labels" => ["api"]}
    from_mcp = mcp(ctx, "create_task", Map.put(args, "project_key", "BOS"))

    from_rest =
      :post |> api_send(ctx.token, w(ctx.slug, "/projects/BOS/tasks"), args) |> rest(201)

    assert %{"id" => "BOS-5", "dispatch" => [%{"result" => "queued"}]} = from_mcp
    assert %{"id" => "BOS-6"} = from_rest
    ids = %{"BOS-5" => "NEW", "BOS-6" => "NEW"}
    assert normalize(from_rest, ids) == normalize(from_mcp, ids)
  end

  test "transition_task with feedback", ctx do
    args = %{"to" => "IN_PROGRESS", "feedback" => %{"kind" => "comment", "content" => "Go"}}
    from_mcp = mcp(ctx, "transition_task", Map.put(args, "task_id", "BOS-1"))

    from_rest =
      :post |> api_send(ctx.token, w(ctx.slug, "/tasks/BOS-2/transition"), args) |> rest(200)

    ids = %{"BOS-1" => "ONE", "BOS-2" => "ONE"}
    assert from_rest["status"] == "IN_PROGRESS"
    assert normalize(from_rest, ids) == normalize(from_mcp, ids)
  end

  test "add_feedback", ctx do
    from_mcp = mcp(ctx, "add_feedback", %{"task_id" => "BOS-1", "content" => "Hi @keel/run"})

    from_rest =
      :post
      |> api_send(ctx.token, w(ctx.slug, "/tasks/BOS-2/feedback"), %{content: "Hi @keel/run"})
      |> rest(201)

    ids = %{"BOS-1" => "ONE", "BOS-2" => "ONE"}
    assert from_rest["author"] == %{"name" => "keel/dev", "kind" => "agent"}
    assert normalize(from_rest, ids) == normalize(from_mcp, ids)
  end

  test "link_tasks", ctx do
    from_mcp =
      mcp(ctx, "link_tasks", %{"from" => "BOS-3", "to" => "BOS-1", "type" => "depends_on"})

    from_rest =
      :post
      |> api_send(ctx.token, w(ctx.slug, "/tasks/BOS-4/links"), %{to: "BOS-2", type: "depends_on"})
      |> rest(200)

    ids = %{"BOS-1" => "ONE", "BOS-2" => "ONE", "BOS-3" => "TWO", "BOS-4" => "TWO"}
    assert normalize(from_rest, ids) == normalize(from_mcp, ids)
  end

  # add-spec-workflow 3.3: the spec endpoints return the spec tools' results.
  describe "specs" do
    setup do
      files = for {p, c} <- Helmsman.TaskSpecsFixtures.spec_files(), do: %{path: p, content: c}
      %{files: files, spec_ids: %{"BOS-1" => "ONE", "BOS-2" => "ONE"}}
    end

    # The two tasks' specs differ only in their task and change_id.
    defp same_spec(value, ids),
      do:
        value
        |> Jason.encode!()
        |> String.replace("add-two", "add-one")
        |> Jason.decode!()
        |> normalize(ids)

    test "update_spec, submit_spec_version, get_spec and diff_spec", ctx do
      from_mcp = mcp(ctx, "update_spec", %{"task_id" => "BOS-1", "change_id" => "add-one"})

      from_rest =
        :patch
        |> api_send(ctx.token, w(ctx.slug, "/tasks/BOS-2/spec"), %{change_id: "add-two"})
        |> rest(201)

      assert same_spec(from_rest, ctx.spec_ids) == same_spec(from_mcp, ctx.spec_ids)

      args = %{"base_version" => 0, "files" => ctx.files, "note" => "First"}
      from_mcp = mcp(ctx, "submit_spec_version", Map.put(args, "task_id", "BOS-1"))

      from_rest =
        :post
        |> api_send(ctx.token, w(ctx.slug, "/tasks/BOS-2/spec/versions"), args)
        |> rest(201)

      assert %{"version" => 1} = from_rest
      assert same_spec(from_rest, ctx.spec_ids) == same_spec(from_mcp, ctx.spec_ids)

      from_mcp = mcp(ctx, "get_spec", %{"task_id" => "BOS-1", "files" => ["tasks.md"]})

      from_rest =
        rest(api_get(ctx.token, w(ctx.slug, "/tasks/BOS-2/spec?files[]=tasks.md")), 200)

      assert same_spec(from_rest, ctx.spec_ids) == same_spec(from_mcp, ctx.spec_ids)

      from_mcp = mcp(ctx, "diff_spec", %{"task_id" => "BOS-1", "from" => 0})
      from_rest = rest(api_get(ctx.token, w(ctx.slug, "/tasks/BOS-2/spec/diff?from=0")), 200)
      assert from_rest == from_mcp
    end

    test "submit_spec_review, reply_spec_issue and list_spec_reviews", ctx do
      for ident <- ["BOS-1", "BOS-2"],
          do: Helmsman.TaskSpecsFixtures.spec_fixture(ctx.scope, ident, change_id: nil)

      review = %{
        "version" => 1,
        "verdict" => "fail",
        "summary" => "Unclear.",
        "issues" => [
          %{"severity" => "P2", "file" => "proposal.md", "line" => 1, "body" => "Why?"}
        ]
      }

      from_mcp = mcp(ctx, "submit_spec_review", Map.put(review, "task_id", "BOS-1"))

      from_rest =
        :post
        |> api_send(ctx.token, w(ctx.slug, "/tasks/BOS-2/spec/reviews"), review)
        |> rest(201)

      assert %{"review" => 1, "issues" => ["R1.1"]} = from_rest
      assert from_rest == from_mcp

      reply = %{"body" => "Taken back.", "resolution" => "withdrawn"}

      from_mcp =
        mcp(ctx, "reply_spec_issue", Map.merge(reply, %{"task_id" => "BOS-1", "issue" => "R1.1"}))

      from_rest =
        :post
        |> api_send(ctx.token, w(ctx.slug, "/tasks/BOS-2/spec/issues/R1.1/notes"), reply)
        |> rest(201)

      assert from_rest == from_mcp

      from_mcp = mcp(ctx, "list_spec_reviews", %{"task_id" => "BOS-1", "version" => 1})

      from_rest =
        rest(api_get(ctx.token, w(ctx.slug, "/tasks/BOS-2/spec/reviews?version=1")), 200)

      assert [%{"issues" => [%{"resolution" => "withdrawn"}]}] = from_rest["reviews"]
      assert normalize(from_rest, ctx.spec_ids) == normalize(from_mcp, ctx.spec_ids)
    end
  end
end
