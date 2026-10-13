defmodule HelmsmanWeb.API.ActorsControllerTest do
  # add-rest-api 2.1 and 8.1: /me/tasks, /actors, /agents (with squads).
  use HelmsmanWeb.ConnCase, async: true

  import Helmsman.AccountsFixtures
  import Helmsman.AgentsFixtures
  import Helmsman.ApiTokensFixtures
  import Helmsman.ProjectsFixtures
  import Helmsman.SquadsFixtures
  import Helmsman.WorkspacesFixtures
  import HelmsmanWeb.APIHelpers
  import OpenApiSpex.TestAssertions

  alias HelmsmanMCP.{Pipeline, Sessions}

  setup_all do
    %{spec: api_spec()}
  end

  setup do
    ctx = api_fixture()
    project_fixture(ctx.scope, %{key: "BOS"})
    ctx
  end

  test "GET /actors lists every identity", ctx do
    data = ctx.token |> api_get(w(ctx.slug, "/actors")) |> body!(200)
    assert_schema(data["data"], "ActorList", ctx.spec)
    assert Enum.any?(data["data"], &(&1["kind"] == "human"))
  end

  test "someone else's agent as X-Helmsman-Actor is 403 on reads too", ctx do
    bob = user_fixture()
    member_fixture(ctx.workspace, bob, :member)
    agent_fixture(ctx.workspace, bob, "bob/dev")

    ctx.token
    |> api_get(w(ctx.slug, "/actors"), [{"x-helmsman-actor", "bob/dev"}])
    |> error!(403, "forbidden")
  end

  test "GET /me/tasks: the tasks of the token's default agent", ctx do
    keel = agent_fixture(ctx.workspace, ctx.alice, "keel/dev")
    token = token_for(ctx.alice, ctx.workspace, %{default_agent_id: keel.id})
    mine = task_fixture(ctx.scope, "BOS", %{assignee: "keel/dev"})
    task_fixture(ctx.scope, "BOS")

    data = token |> api_get(w(ctx.slug, "/me/tasks")) |> body!(200)
    assert_schema(data["data"], "TaskList", ctx.spec)
    assert Enum.map(data["data"], & &1["id"]) == [mine.ident]

    # Without a default agent: the human identity, who has none.
    assert ctx.token |> api_get(w(ctx.slug, "/me/tasks")) |> body!(200) == %{"data" => []}

    data =
      ctx.token
      |> api_get(w(ctx.slug, "/me/tasks"), [{"x-helmsman-actor", "keel/dev"}])
      |> body!(200)

    assert Enum.map(data["data"], & &1["id"]) == [mine.ident]
  end

  test "GET /agents: agents and squads, as MCP list_agents returns them", ctx do
    managed_agent_fixture(ctx.scope, %{name: "keel/dev"})
    managed_agent_fixture(ctx.scope, %{name: "keel/review"})

    squad_fixture(ctx.scope, %{
      name: "keel",
      leader: "keel/dev",
      members: [%{name: "keel/review"}]
    })

    data = ctx.token |> api_get(w(ctx.slug, "/agents")) |> body!(200)
    assert_schema(data["data"], "AgentList", ctx.spec)
    assert [%{"name" => "keel", "leader" => "keel/dev"}] = data["data"]["squads"]

    scope = token_scope_fixture(ctx.alice, ctx.workspace, :mcp, ctx.api_token)
    sid = "rest-#{System.unique_integer([:positive])}"
    :ok = Sessions.register(sid, scope, self())
    {:ok, json} = Pipeline.call_tool("list_agents", %{}, scope, sid)
    assert data["data"] == Jason.decode!(json)
  end
end
