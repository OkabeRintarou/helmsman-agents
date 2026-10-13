defmodule HelmsmanWeb.API.OpenAPITest do
  # add-rest-api 4.1 / 4.2 and decision 8: the document cannot drift from
  # the routes, and errors match the Error schema. Changes the token rate
  # limit with Application.put_env.
  use HelmsmanWeb.ConnCase, async: false

  import ExUnit.CaptureLog
  import Helmsman.ProjectsFixtures
  import HelmsmanWeb.APIHelpers
  import OpenApiSpex.TestAssertions

  alias HelmsmanMCP.Tools.ListTasks
  alias HelmsmanWeb.API.{ImportBodyPlug, Operations, Params}
  alias HelmsmanWeb.ErrorMapper
  alias OpenApiSpex.OpenApi
  alias OpenApiSpex.OpenApi.Decode

  defmodule ListTasksPlus do
    @moduledoc false
    # list_tasks with one more optional argument.
    def name, do: ListTasks.name()
    def description, do: ListTasks.description()
    def mode, do: ListTasks.mode()

    def input_schema,
      do: Map.put(ListTasks.input_schema(), :sort_by, {:string, description: "New argument."})
  end

  @verbs ~w(get post put patch delete)a

  defp routes do
    for route <- HelmsmanWeb.Router.__routes__(),
        String.starts_with?(route.path, "/api/v1/"),
        do: {route.verb, String.replace(route.path, ~r/:(\w+)/, "{\\1}")}
  end

  defp operations(spec) do
    for {path, item} <- spec.paths,
        verb <- @verbs,
        op = Map.get(item, verb),
        op != nil,
        do: {verb, path}
  end

  test "every /api/v1 route has an operation and every operation a route" do
    spec = api_spec()

    upload_routes =
      Enum.map(ImportBodyPlug.routes(), fn {verb, path} ->
        {verb, String.replace(path, ~r/:(\w+)/, "{\\1}")}
      end)

    routes = MapSet.new(routes() ++ upload_routes)

    assert MapSet.size(routes) >= 28
    assert routes == MapSet.new(operations(spec))
  end

  test "public operations need no credentials; the others the bearer token" do
    spec = api_spec()
    assert spec.security == [%{"bearer" => []}]

    for {path, item} <- spec.paths, verb <- @verbs, op = Map.get(item, verb), op != nil do
      public? = path in ["/api/v1/workflow.md", "/api/v1/openapi.json"]
      assert op.security == [] == public?, "#{verb} #{path}"

      for {status, response} <- op.responses, status >= 400 do
        assert %{"application/json" => %{schema: %{"$ref": "#/components/schemas/Error"}}} =
                 response.content,
               "#{verb} #{path} #{status}"
      end

      success = op.responses |> Map.keys() |> Enum.filter(&(&1 < 400))
      assert [_one] = success, "#{verb} #{path}"
    end
  end

  test "the document encodes to JSON and decodes back" do
    map = api_spec() |> Jason.encode!() |> Jason.decode!()
    assert %OpenApi{} = Decode.decode(map)
    assert map["components"]["securitySchemes"]["bearer"]["scheme"] == "bearer"
  end

  test "GET /api/v1/openapi.json needs no credentials", %{conn: conn} do
    assert %{"paths" => paths} = conn |> get("/api/v1/openapi.json") |> json_response(200)
    assert Map.has_key?(paths, "/api/v1/w/{slug}/projects/{key}/tasks")
  end

  test "tool endpoints take their parameters from the tool" do
    op = Operations.tool(ListTasks, path: [project_key: "key"])
    names = Enum.map(op.parameters, & &1.name)
    assert :key in names and :status in names and :limit in names
    refute :project_key in names
    assert op.description =~ ListTasks.description()

    op = Operations.tool(HelmsmanMCP.Tools.CreateTask, path: [project_key: "key"])
    body = op.requestBody.content["application/json"].schema
    assert "title" in body.required
    refute Map.has_key?(body.properties, "project_key")
    assert Map.has_key?(body.properties, "actor")
  end

  test "a new tool argument shows up in the document and REST accepts it" do
    op = Operations.tool(ListTasksPlus, path: [project_key: "key"])
    assert %{in: :query, required: false} = Enum.find(op.parameters, &(&1.name == :sort_by))

    conn = Plug.Test.conn(:get, "/x?sort_by=title&limit=2")

    assert {:ok, %{"sort_by" => "title", "limit" => 2, "project_key" => "BOS"}, nil} =
             Params.tool_args(conn, ListTasksPlus, %{"project_key" => "BOS"})
  end

  describe "error bodies match the Error schema" do
    setup do
      ctx = api_fixture()
      project_fixture(ctx.scope, %{key: "BOS"})
      task_fixture(ctx.scope, "BOS")
      Map.put(ctx, :spec, api_spec())
    end

    defp assert_error_schema(conn, status, spec) do
      assert conn.status == status, conn.resp_body
      assert_schema(Jason.decode!(conn.resp_body), "Error", spec)
    end

    test "400 401 403 404 409 415 422", ctx do
      %{token: token, slug: slug, spec: spec} = ctx

      token |> api_get(w(slug, "/projects/BOS/tasks?limit=x")) |> assert_error_schema(400, spec)
      "hm_bad" |> api_get(w(slug, "/projects")) |> assert_error_schema(401, spec)

      token
      |> api_get(w(slug, "/projects"), [{"x-helmsman-actor", "nobody/x"}])
      |> assert_error_schema(403, spec)

      token |> api_get(w(slug, "/tasks/BOS-99")) |> assert_error_schema(404, spec)

      :patch
      |> api_send(token, w(slug, "/tasks/BOS-1"), %{title: "x", lock_version: 99})
      |> assert_error_schema(409, spec)

      token
      |> authed([{"content-type", "text/plain"}, {"content-length", "1"}])
      |> post(w(slug, "/projects/BOS/tasks"), "x")
      |> assert_error_schema(415, spec)

      :post
      |> api_send(token, w(slug, "/projects/BOS/tasks"), %{title: ""})
      |> assert_error_schema(422, spec)
    end

    test "413 and invalid JSON", ctx do
      {413, _headers, body} =
        assert_error_sent(413, fn ->
          api_send(
            :post,
            ctx.token,
            w(ctx.slug, "/projects/BOS/tasks"),
            String.duplicate(" ", 8_100_000) <> "{}"
          )
        end)

      assert_schema(Jason.decode!(body), "Error", ctx.spec)

      {400, _headers, body} =
        assert_error_sent(400, fn ->
          api_send(:post, ctx.token, w(ctx.slug, "/projects/BOS/tasks"), "{")
        end)

      assert_schema(Jason.decode!(body), "Error", ctx.spec)
    end

    test "429", ctx do
      previous = Application.get_env(:helmsman, :api_token_rate_limit)
      Application.put_env(:helmsman, :api_token_rate_limit, 1)
      on_exit(fn -> Application.put_env(:helmsman, :api_token_rate_limit, previous) end)

      assert ctx.token |> api_get(w(ctx.slug, "/projects")) |> body!(200)
      ctx.token |> api_get(w(ctx.slug, "/projects")) |> assert_error_schema(429, ctx.spec)
    end

    test "500", ctx do
      capture_log(fn ->
        {500, body} = ErrorMapper.to_response(:surprise)
        assert_schema(body |> Jason.encode!() |> Jason.decode!(), "Error", ctx.spec)
      end)
    end
  end
end
