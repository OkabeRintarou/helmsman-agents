defmodule HelmsmanWeb.API.LinksControllerTest do
  # add-rest-api 2.2: links.
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
    for _ <- 1..2, do: task_fixture(ctx.scope, "BOS")
    ctx
  end

  test "POST adds a link from the task in the path", ctx do
    data =
      :post
      |> api_send(ctx.token, w(ctx.slug, "/tasks/BOS-2/links"), %{to: "BOS-1", type: "depends_on"})
      |> body!(200)

    assert_schema(data["data"], "TaskDetail", ctx.spec)
    assert %{"id" => "BOS-2", "blocked" => true, "links" => [link]} = data["data"]
    assert %{"type" => "depends_on", "direction" => "out", "task" => "BOS-1"} = link
  end

  test "DELETE removes it, twice: both 200", ctx do
    :post
    |> api_send(ctx.token, w(ctx.slug, "/tasks/BOS-2/links"), %{to: "BOS-1", type: "depends_on"})
    |> body!(200)

    for _ <- 1..2 do
      data =
        :delete
        |> api_send(ctx.token, w(ctx.slug, "/tasks/BOS-2/links/depends_on/BOS-1"))
        |> body!(200)

      assert_schema(data["data"], "TaskDetail", ctx.spec)
      assert %{"links" => [], "blocked" => false} = data["data"]
    end
  end

  test "a cycle is 409 with its path; a self link and an unknown type 422", ctx do
    :post
    |> api_send(ctx.token, w(ctx.slug, "/tasks/BOS-2/links"), %{to: "BOS-1", type: "depends_on"})
    |> body!(200)

    detail =
      :post
      |> api_send(ctx.token, w(ctx.slug, "/tasks/BOS-1/links"), %{to: "BOS-2", type: "depends_on"})
      |> error!(409, "cycle")

    assert detail == %{"path" => ["BOS-1", "BOS-2", "BOS-1"]}

    :post
    |> api_send(ctx.token, w(ctx.slug, "/tasks/BOS-1/links"), %{to: "BOS-1", type: "depends_on"})
    |> error!(422, "self_link")

    :post
    |> api_send(ctx.token, w(ctx.slug, "/tasks/BOS-1/links"), %{to: "BOS-2", type: "blocks"})
    |> error!(422, "invalid_type")
  end
end
