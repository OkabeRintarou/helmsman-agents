defmodule HelmsmanWeb.API.SearchControllerTest do
  # add-rest-api 2.2: search.
  use HelmsmanWeb.ConnCase, async: true

  import Helmsman.ProjectsFixtures
  import HelmsmanWeb.APIHelpers
  import OpenApiSpex.TestAssertions

  setup_all do
    %{spec: api_spec()}
  end

  setup do
    ctx = api_fixture()
    project_fixture(ctx.scope, %{key: "BOS"})
    task_fixture(ctx.scope, "BOS", %{title: "Fix the login page"})
    task_fixture(ctx.scope, "BOS", %{title: "Write docs"})
    ctx
  end

  test "GET /search finds tasks", ctx do
    data = ctx.token |> api_get(w(ctx.slug, "/search?query=login&limit=5")) |> body!(200)
    assert_schema(data["data"], "SearchResult", ctx.spec)
    assert [%{"id" => "BOS-1", "title" => "Fix the login page"}] = data["data"]
  end

  test "the query is required; a too long one is 422", ctx do
    detail = ctx.token |> api_get(w(ctx.slug, "/search")) |> error!(400, "invalid_params")
    assert Map.keys(detail["fields"]) == ["query"]

    long = String.duplicate("a", 201)
    ctx.token |> api_get(w(ctx.slug, "/search?query=#{long}")) |> error!(422, "invalid_query")
  end
end
