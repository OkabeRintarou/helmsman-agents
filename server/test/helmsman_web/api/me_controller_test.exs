defmodule HelmsmanWeb.API.MeControllerTest do
  # add-rest-api 3.1: GET /me.
  use HelmsmanWeb.ConnCase, async: true

  import Helmsman.ApiTokensFixtures
  import HelmsmanWeb.APIHelpers
  import OpenApiSpex.TestAssertions

  setup_all do
    %{spec: api_spec()}
  end

  setup do
    ctx = api_fixture(%{scopes: ["api:read"]})
    keel = agent_fixture(ctx.workspace, ctx.alice, "keel/dev")
    agent_fixture(ctx.workspace, ctx.alice, "keel/review")
    human = Helmsman.Actors.get_human(ctx.workspace.id, ctx.alice.id)
    Map.merge(ctx, %{keel: keel, human: human})
  end

  test "without a default agent: the human identity", ctx do
    data = ctx.token |> api_get(w(ctx.slug, "/me")) |> body!(200)
    assert_schema(data["data"], "Me", ctx.spec)

    assert %{
             "user" => %{"name" => name},
             "workspace" => %{"slug" => slug},
             "role" => "owner",
             "actor" => %{"name" => name, "kind" => "human"},
             "actor_source" => "human",
             "token" => %{"scopes" => ["api:read"], "prefix" => prefix}
           } = data["data"]

    assert name == ctx.human.name
    assert slug == ctx.slug
    assert String.starts_with?(ctx.token, "hm_" <> prefix)
    refute Jason.encode!(data) =~ ctx.alice.email
  end

  test "the token's default agent", ctx do
    token = token_for(ctx.alice, ctx.workspace, %{default_agent_id: ctx.keel.id})
    data = token |> api_get(w(ctx.slug, "/me")) |> body!(200)

    assert %{"actor" => %{"name" => "keel/dev", "kind" => "agent"}, "actor_source" => "default"} =
             data["data"]

    assert data["data"]["user"]["name"] == ctx.human.name
  end

  test "the X-Helmsman-Actor header", ctx do
    data =
      ctx.token
      |> api_get(w(ctx.slug, "/me"), [{"x-helmsman-actor", "keel/review"}])
      |> body!(200)

    assert %{"actor" => %{"name" => "keel/review"}, "actor_source" => "header"} = data["data"]

    ctx.token
    |> api_get(w(ctx.slug, "/me"), [{"x-helmsman-actor", "nobody/else"}])
    |> error!(403, "forbidden")
  end
end
