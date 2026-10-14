defmodule HelmsmanWeb.API.AvatarsControllerTest do
  # add-actor-avatars 7.3: actor-avatars「读取头像」(the API route) and
  # 「身份视图中的头像地址」(list_actors, list_agents, whoami, /me over MCP
  # and REST; decision 13 and its record).
  use HelmsmanWeb.ConnCase, async: true

  import Helmsman.AccountsFixtures
  import Helmsman.ApiTokensFixtures
  import Helmsman.AvatarsFixtures
  import Helmsman.ProjectsFixtures
  import Helmsman.RunsFixtures
  import Helmsman.SquadsFixtures
  import Helmsman.WorkspacesFixtures
  import HelmsmanMCP.ToolHelpers
  import HelmsmanWeb.APIHelpers
  import OpenApiSpex.TestAssertions

  alias Helmsman.{Avatars, Config, Daemons}
  alias HelmsmanMCP.Sessions

  setup_all do
    %{spec: api_spec()}
  end

  setup do
    ctx = squads_fixture()
    slug = ctx.workspace.slug
    token = token_for(ctx.alice, ctx.workspace)
    {:ok, %{key: alice_key}} = Avatars.put(ctx.alice_scope, :me, png(64, 64))
    agent_png = png(64, 64, color: {0, 200, 0, 255})
    {:ok, %{key: agent_key}} = Avatars.put(ctx.alice_scope, {:actor, "keel/dev"}, agent_png)
    {:ok, %{key: squad_key}} = Avatars.put(ctx.alice_scope, {:actor, "web-team"}, png(40, 40))

    Map.merge(ctx, %{
      slug: slug,
      token: token,
      alice_key: alice_key,
      agent_key: agent_key,
      agent_png: agent_png,
      squad_key: squad_key
    })
  end

  defp avatar_url(slug, key), do: "#{Config.public_url()}/api/v1/w/#{slug}/avatars/#{key}"
  defp path(url), do: URI.parse(url).path
  defp by_name(items, name), do: Enum.find(items, &(&1["name"] == name))

  defp running_run_scope(ctx) do
    task = task_fixture(ctx.alice_scope, ctx.project.key)
    run = run_fixture(ctx.agent, %{task_id: task.id, status: :running})
    run_scope_fixture(run)
  end

  describe "GET /api/v1/w/:slug/avatars/:key" do
    test "tokens with mcp, api:read or api:write read it", ctx do
      for scopes <- [["mcp"], ["api:read"], ["api:write"]] do
        token = token_for(ctx.alice, ctx.workspace, %{scopes: scopes})

        conn =
          token
          |> authed([{"accept", "image/*"}])
          |> get(w(ctx.slug, "/avatars/#{ctx.agent_key}"))

        assert conn.status == 200, inspect(scopes)
        assert conn.resp_body == ctx.agent_png
        assert get_resp_header(conn, "content-type") == ["image/png"]
        assert get_resp_header(conn, "etag") == [~s("#{ctx.agent_key}")]
        assert get_resp_header(conn, "cache-control") == ["private, max-age=31536000, immutable"]
        assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
        assert get_resp_header(conn, "content-security-policy") == ["default-src 'none'; sandbox"]
      end
    end

    test "If-None-Match is 304", ctx do
      conn =
        ctx.token
        |> authed([{"if-none-match", ~s("#{ctx.agent_key}")}])
        |> get(w(ctx.slug, "/avatars/#{ctx.agent_key}"))

      assert conn.status == 304
      assert conn.resp_body == ""
    end

    test "a member's user avatar is readable", ctx do
      {:ok, %{key: key}} = Avatars.put(ctx.bob_scope, :me, webp(64, 64))
      assert ctx.token |> api_get(w(ctx.slug, "/avatars/#{key}")) |> Map.get(:status) == 200
    end

    test "run tokens, daemon tokens, no token and revoked tokens are 401", ctx do
      {_scope, run_token} = running_run_scope(ctx)
      daemon_token = Daemons.new_token()

      for token <- [run_token, daemon_token, nil, "hm_bogus"] do
        token |> api_get(w(ctx.slug, "/avatars/#{ctx.agent_key}")) |> error!(401, "unauthorized")
      end

      %{token: token, api_token: api_token} =
        api_token_fixture(ctx.alice_scope, %{scopes: ["mcp"]})

      assert token |> api_get(w(ctx.slug, "/avatars/#{ctx.agent_key}")) |> Map.get(:status) == 200
      {:ok, _} = Helmsman.ApiTokens.revoke(ctx.alice_scope, api_token.id)
      token |> api_get(w(ctx.slug, "/avatars/#{ctx.agent_key}")) |> error!(401, "unauthorized")
    end

    test "another workspace's slug or key, an unknown or malformed key are 404", ctx do
      outsider = user_fixture()
      other = workspace_fixture(outsider)
      other_token = token_for(outsider, other)
      {:ok, %{key: other_key}} = Avatars.put(user_scope_fixture(outsider), :me, png(48, 48))

      other_token |> api_get(w(ctx.slug, "/avatars/#{ctx.agent_key}")) |> error!(404, "not_found")

      other_token
      |> api_get(w(other.slug, "/avatars/#{ctx.agent_key}"))
      |> error!(404, "not_found")

      ctx.token |> api_get(w(ctx.slug, "/avatars/#{other_key}")) |> error!(404, "not_found")

      ctx.token
      |> api_get(w(ctx.slug, "/avatars/#{String.duplicate("a", 32)}"))
      |> error!(404, "not_found")

      ctx.token |> api_get(w(ctx.slug, "/avatars/nope")) |> error!(404, "not_found")
    end

    test "the mcp scope is accepted on this route only", ctx do
      token = token_for(ctx.alice, ctx.workspace, %{scopes: ["mcp"]})

      for path <- ["/actors", "/agents", "/me"] do
        token |> api_get(w(ctx.slug, path)) |> error!(403, "insufficient_scope")
      end
    end

    test "the operation is documented", ctx do
      op = ctx.spec.paths["/api/v1/w/{slug}/avatars/{key}"].get
      assert op.operationId == "get_avatar"
      assert Map.has_key?(op.responses[200].content, "image/*")
    end
  end

  describe "REST views" do
    test "GET /actors: has_avatar and an address the token can read", ctx do
      data = ctx.token |> api_get(w(ctx.slug, "/actors")) |> body!(200)
      assert_schema(data["data"], "ActorList", ctx.spec)
      actors = data["data"]

      assert %{"has_avatar" => true, "avatar_url" => alice_url} =
               by_name(actors, ctx.alice_scope.actor.name)

      assert alice_url == avatar_url(ctx.slug, ctx.alice_key)

      assert %{"has_avatar" => true, "avatar_url" => agent_url} = by_name(actors, "keel/dev")
      assert agent_url == avatar_url(ctx.slug, ctx.agent_key)

      assert %{"has_avatar" => false, "avatar_url" => nil} =
               by_name(actors, ctx.bob_scope.actor.name)

      assert %{"has_avatar" => false, "avatar_url" => nil} = by_name(actors, "helmsman")

      conn = ctx.token |> authed() |> get(path(agent_url))
      assert conn.status == 200 and conn.resp_body == ctx.agent_png
    end

    test "GET /agents: agents and squads", ctx do
      data = ctx.token |> api_get(w(ctx.slug, "/agents")) |> body!(200)
      assert_schema(data["data"], "AgentList", ctx.spec)

      assert %{"has_avatar" => true, "avatar_url" => agent_url} =
               by_name(data["data"]["agents"], "keel/dev")

      assert agent_url == avatar_url(ctx.slug, ctx.agent_key)

      assert %{"has_avatar" => false, "avatar_url" => nil} =
               by_name(data["data"]["agents"], "keel/fe")

      assert %{"has_avatar" => true, "avatar_url" => squad_url} =
               by_name(data["data"]["squads"], "web-team")

      assert squad_url == avatar_url(ctx.slug, ctx.squad_key)
    end

    test "GET /me: the user and the actor", ctx do
      data = ctx.token |> api_get(w(ctx.slug, "/me")) |> body!(200)
      assert_schema(data["data"], "Me", ctx.spec)
      alice_url = avatar_url(ctx.slug, ctx.alice_key)

      assert %{"has_avatar" => true, "avatar_url" => ^alice_url} = data["data"]["user"]
      assert %{"has_avatar" => true, "avatar_url" => ^alice_url} = data["data"]["actor"]

      data =
        ctx.token
        |> api_get(w(ctx.slug, "/me"), [{"x-helmsman-actor", "keel/dev"}])
        |> body!(200)

      agent_url = avatar_url(ctx.slug, ctx.agent_key)

      assert %{"name" => "keel/dev", "has_avatar" => true, "avatar_url" => ^agent_url} =
               data["data"]["actor"]

      bob_token = token_for(ctx.bob, ctx.workspace)
      data = bob_token |> api_get(w(ctx.slug, "/me")) |> body!(200)
      assert %{"has_avatar" => false, "avatar_url" => nil} = data["data"]["user"]
      assert %{"has_avatar" => false, "avatar_url" => nil} = data["data"]["actor"]
    end
  end

  describe "MCP views" do
    test "an hm_ token: list_actors, list_agents and whoami give readable addresses", ctx do
      %{token: token, api_token: api_token} =
        api_token_fixture(ctx.alice_scope, %{scopes: ["mcp"]})

      session = %{
        scope: token_scope_fixture(ctx.alice, ctx.workspace, :mcp, api_token),
        sid: "s#{System.unique_integer([:positive])}"
      }

      :ok = Sessions.register(session.sid, session.scope, self())

      actors = call!(session, "list_actors")
      agent_url = avatar_url(ctx.slug, ctx.agent_key)
      assert %{"has_avatar" => true, "avatar_url" => ^agent_url} = by_name(actors, "keel/dev")
      assert %{"has_avatar" => false, "avatar_url" => nil} = by_name(actors, "helmsman")

      agents = call!(session, "list_agents")
      assert %{"avatar_url" => ^agent_url} = by_name(agents["agents"], "keel/dev")
      squad_url = avatar_url(ctx.slug, ctx.squad_key)

      assert %{"has_avatar" => true, "avatar_url" => ^squad_url} =
               by_name(agents["squads"], "web-team")

      conn = token |> authed() |> get(path(agent_url))
      assert conn.status == 200 and conn.resp_body == ctx.agent_png

      call!(session, "identify", %{name: "keel/dev"})
      whoami = call!(session, "whoami")

      assert %{"name" => "keel/dev", "has_avatar" => true, "avatar_url" => ^agent_url} =
               whoami["actor"]
    end

    test "REST and MCP give the same addresses for the same token", ctx do
      %{token: token, api_token: api_token} = api_token_fixture(ctx.alice_scope)

      session = %{
        scope: token_scope_fixture(ctx.alice, ctx.workspace, :mcp, api_token),
        sid: "s#{System.unique_integer([:positive])}"
      }

      :ok = Sessions.register(session.sid, session.scope, self())

      rest = token |> api_get(w(ctx.slug, "/actors")) |> body!(200)
      mcp = call!(session, "list_actors")
      fields = &Enum.map(&1, fn item -> Map.take(item, ["name", "has_avatar", "avatar_url"]) end)
      assert fields.(rest["data"]) == fields.(mcp)
    end

    test "a run token: has_avatar, never an address", ctx do
      {run_scope, _token} = running_run_scope(ctx)
      session = %{scope: run_scope, sid: "run-#{System.unique_integer([:positive])}"}
      :ok = Sessions.register(session.sid, run_scope, self())

      actors = call!(session, "list_actors")
      assert %{"has_avatar" => true, "avatar_url" => nil} = by_name(actors, "keel/dev")

      assert %{"has_avatar" => true, "avatar_url" => nil} =
               by_name(actors, ctx.alice_scope.actor.name)

      agents = call!(session, "list_agents")
      assert %{"has_avatar" => true, "avatar_url" => nil} = by_name(agents["agents"], "keel/dev")
      assert %{"has_avatar" => true, "avatar_url" => nil} = by_name(agents["squads"], "web-team")

      whoami = call!(session, "whoami")
      assert %{"name" => "keel/dev", "has_avatar" => true, "avatar_url" => nil} = whoami["actor"]
    end
  end

  # update-actor-icons 3.3 (D14): an icon is not an image avatar.
  describe "built-in icons" do
    setup ctx do
      {:ok, _} = Avatars.put_icon(ctx.alice_scope, {:actor, "keel/dev"}, "zai")
      {:ok, _} = Avatars.put_icon(ctx.alice_scope, :me, "zai")
      :ok
    end

    test "REST: no avatar, no address, no icon key; the old image is gone", ctx do
      agents = ctx.token |> api_get(w(ctx.slug, "/agents")) |> body!(200)

      assert %{"has_avatar" => false, "avatar_url" => nil} =
               by_name(agents["data"]["agents"], "keel/dev")

      me = ctx.token |> api_get(w(ctx.slug, "/me")) |> body!(200)
      assert %{"has_avatar" => false, "avatar_url" => nil} = me["data"]["user"]
      assert %{"has_avatar" => false, "avatar_url" => nil} = me["data"]["actor"]

      for body <- [agents, me, ctx.token |> api_get(w(ctx.slug, "/actors")) |> body!(200)] do
        refute Jason.encode!(body) =~ "zai"
      end

      for key <- [ctx.agent_key, ctx.alice_key] do
        ctx.token |> api_get(w(ctx.slug, "/avatars/#{key}")) |> error!(404, "not_found")
      end
    end

    test "MCP: list_agents, list_actors and whoami", ctx do
      %{api_token: api_token} = api_token_fixture(ctx.alice_scope, %{scopes: ["mcp"]})

      session = %{
        scope: token_scope_fixture(ctx.alice, ctx.workspace, :mcp, api_token),
        sid: "s#{System.unique_integer([:positive])}"
      }

      :ok = Sessions.register(session.sid, session.scope, self())
      agents = call!(session, "list_agents")
      assert %{"has_avatar" => false, "avatar_url" => nil} = by_name(agents["agents"], "keel/dev")
      actors = call!(session, "list_actors")
      assert %{"has_avatar" => false, "avatar_url" => nil} = by_name(actors, "keel/dev")

      assert %{"has_avatar" => false, "avatar_url" => nil} =
               by_name(actors, ctx.alice_scope.actor.name)

      call!(session, "identify", %{name: "keel/dev"})
      whoami = call!(session, "whoami")
      assert %{"has_avatar" => false, "avatar_url" => nil} = whoami["actor"]

      for payload <- [agents, actors, whoami], do: refute(Jason.encode!(payload) =~ "zai")
    end
  end
end
