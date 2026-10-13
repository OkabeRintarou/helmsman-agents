defmodule HelmsmanWeb.API.PipelineTest do
  # rest-api "请求参数" (non-JSON bodies) and "错误体与状态码" (unknown
  # paths); add-rest-api decisions 4 and 5.
  use HelmsmanWeb.ConnCase, async: true

  import Helmsman.ProjectsFixtures
  import HelmsmanWeb.APIHelpers

  alias Helmsman.Repo
  alias Helmsman.Tasks.Task

  setup do
    ctx = api_fixture()
    project_fixture(ctx.scope, %{key: "BOS"})
    ctx
  end

  test "a body that is not JSON is 415 and writes nothing", %{token: token, slug: slug} do
    body = "title=Fix"

    for type <- ["text/plain", "application/x-www-form-urlencoded"] do
      conn =
        token
        |> authed([{"content-type", type}, {"content-length", "#{byte_size(body)}"}])
        |> post(w(slug, "/projects/BOS/tasks"), body)

      error!(conn, 415, "unsupported_media_type")
    end

    assert Repo.aggregate(Task, :count) == 0
  end

  test "a write without a body is not checked", %{token: token, slug: slug} do
    conn = api_send(:post, token, w(slug, "/runs/1/cancel"))
    error!(conn, 404, "not_found")
  end

  test "an unknown /api path is a JSON 404 whatever the Accept header", %{
    token: token,
    slug: slug
  } do
    for accept <- [nil, "text/html", "application/json"] do
      headers = if accept, do: [{"accept", accept}], else: []
      conn = api_get(token, w(slug, "/nope"), headers)
      error!(conn, 404, "not_found")
      assert ["application/json" <> _] = get_resp_header(conn, "content-type")

      api_get(nil, "/api/v2/anything", headers) |> error!(404, "not_found")
      :put |> api_send(token, w(slug, "/projects"), %{}, headers) |> error!(404, "not_found")
    end
  end

  test "an Accept header JSON cannot satisfy is a JSON 406 on known routes",
       %{token: token, slug: slug} do
    spec = api_spec()

    requests = [
      fn h -> api_get(token, w(slug, "/projects"), h) end,
      fn h -> api_send(:post, token, w(slug, "/projects/BOS/tasks"), %{title: "x"}, h) end,
      fn h -> api_get(nil, "/api/v1/openapi.json", h) end,
      fn h -> api_get(nil, "/api/v1/workflow.md", h) end
    ]

    for request <- requests, accept <- ["text/html", "application/xml"] do
      {406, headers, body} = assert_error_sent(406, fn -> request.([{"accept", accept}]) end)

      assert {"content-type", "application/json" <> _} = List.keyfind(headers, "content-type", 0)
      body = Jason.decode!(body)
      assert %{"error" => "not_acceptable", "detail" => %{}} = body
      OpenApiSpex.TestAssertions.assert_schema(body, "Error", spec)
    end

    assert Repo.aggregate(Task, :count) == 0
  end

  test "workflow.md also accepts text/markdown; JSON routes accept */*", %{
    token: token,
    slug: slug
  } do
    conn = api_get(nil, "/api/v1/workflow.md", [{"accept", "text/markdown"}])
    assert conn.status == 200

    assert token |> api_get(w(slug, "/projects"), [{"accept", "*/*"}]) |> body!(200)
  end

  test "browser routes keep their HTML errors" do
    {406, headers, _body} =
      assert_error_sent(406, fn ->
        build_conn() |> put_req_header("accept", "application/xml") |> get("/users/log-in")
      end)

    assert {"content-type", "text/html" <> _} = List.keyfind(headers, "content-type", 0)
  end

  test "a body that is not valid JSON is 400 invalid_json", %{token: token, slug: slug} do
    {400, _headers, body} =
      assert_error_sent(400, fn ->
        api_send(:post, token, w(slug, "/projects/BOS/tasks"), ~s({"title": ))
      end)

    assert %{"error" => "invalid_json", "message" => _, "detail" => %{}} = Jason.decode!(body)
  end

  test "a body over 8 MB is 413", %{token: token, slug: slug} do
    big = Jason.encode!(%{title: String.duplicate("x", 8_100_000)})

    {413, _headers, body} =
      assert_error_sent(413, fn ->
        api_send(:post, token, w(slug, "/projects/BOS/tasks"), big)
      end)

    assert %{"error" => "payload_too_large", "detail" => %{}} = Jason.decode!(body)
  end

  test "a JSON body that is not an object is 400 invalid_params", %{token: token, slug: slug} do
    for body <- ["[1, 2]", "\"text\"", "42"] do
      detail =
        :post
        |> api_send(token, w(slug, "/projects/BOS/tasks"), body)
        |> error!(400, "invalid_params")

      assert %{"fields" => %{"body" => [_]}} = detail
    end

    assert Repo.aggregate(Task, :count) == 0
  end
end
