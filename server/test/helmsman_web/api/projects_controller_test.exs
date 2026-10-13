defmodule HelmsmanWeb.API.ProjectsControllerTest do
  # add-rest-api 2.1: projects.
  use HelmsmanWeb.ConnCase, async: true

  import Helmsman.ProjectsFixtures
  import HelmsmanWeb.APIHelpers
  import OpenApiSpex.TestAssertions

  alias Helmsman.Projects

  setup_all do
    %{spec: api_spec()}
  end

  setup do
    ctx = api_fixture()
    project_fixture(ctx.scope, %{key: "BOS", name: "Bosun"})
    project_fixture(ctx.scope, %{key: "OLD", name: "Old"})
    {:ok, _} = Projects.archive(ctx.scope, "OLD")
    ctx
  end

  test "GET /projects lists the active projects; include_archived=true all", ctx do
    data = ctx.token |> api_get(w(ctx.slug, "/projects")) |> body!(200)
    assert_schema(data["data"], "ProjectList", ctx.spec)
    assert Enum.map(data["data"], & &1["key"]) == ["BOS"]

    data = ctx.token |> api_get(w(ctx.slug, "/projects?include_archived=true")) |> body!(200)
    assert data["data"] |> Enum.map(& &1["key"]) |> Enum.sort() == ["BOS", "OLD"]

    detail =
      ctx.token
      |> api_get(w(ctx.slug, "/projects?include_archived=maybe"))
      |> error!(400, "invalid_params")

    assert_schema(
      %{"error" => "invalid_params", "message" => "m", "detail" => detail},
      "Error",
      ctx.spec
    )

    assert Map.keys(detail["fields"]) == ["include_archived"]
  end

  test "POST /projects creates a project: 201", ctx do
    data =
      :post
      |> api_send(ctx.token, w(ctx.slug, "/projects"), %{key: "NEW", name: "New one"})
      |> body!(201)

    assert_schema(data["data"], "Project", ctx.spec)
    assert %{"key" => "NEW", "name" => "New one", "archived" => false} = data["data"]
  end

  test "a member cannot create a project: 403 forbidden", ctx do
    {_bob, token} = member_token(ctx.workspace, :member)

    :post
    |> api_send(token, w(ctx.slug, "/projects"), %{key: "NOPE", name: "No"})
    |> error!(403, "forbidden")

    assert {:error, :not_found} = Projects.get(ctx.scope, "NOPE")
  end

  test "an invalid key is 422 validation_failed", ctx do
    detail =
      :post
      |> api_send(ctx.token, w(ctx.slug, "/projects"), %{key: "bad key!", name: "x"})
      |> error!(422, "validation_failed")

    assert %{"fields" => %{"key" => [_ | _]}} = detail
  end

  test "GET /projects/:key", ctx do
    data = ctx.token |> api_get(w(ctx.slug, "/projects/BOS")) |> body!(200)
    assert_schema(data["data"], "Project", ctx.spec)
    assert data["data"]["key"] == "BOS"

    ctx.token |> api_get(w(ctx.slug, "/projects/NONE")) |> error!(404, "not_found")
  end

  test "PATCH /projects/:key changes the given fields only", ctx do
    data =
      :patch
      |> api_send(ctx.token, w(ctx.slug, "/projects/BOS"), %{description: "Ships"})
      |> body!(200)

    assert_schema(data["data"], "Project", ctx.spec)
    assert %{"name" => "Bosun", "description" => "Ships"} = data["data"]

    data =
      :patch
      |> api_send(ctx.token, w(ctx.slug, "/projects/BOS"), %{description: nil})
      |> body!(200)

    assert data["data"]["description"] in [nil, ""]
  end

  test "a viewer cannot change a project", ctx do
    {_viewer, token} = member_token(ctx.workspace, :viewer)

    :patch
    |> api_send(token, w(ctx.slug, "/projects/BOS"), %{name: "x"})
    |> error!(403, "forbidden")
  end
end
