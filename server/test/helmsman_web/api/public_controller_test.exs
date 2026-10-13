defmodule HelmsmanWeb.API.PublicControllerTest do
  # add-rest-api 3.2: the public endpoints. Changes the rate limits with
  # Application.put_env.
  use HelmsmanWeb.ConnCase, async: false

  import Helmsman.RateLimitHelpers

  @en File.read!(Path.expand("../../../../docs/AGENT-WORKFLOW.en.md", __DIR__))
  @zh File.read!(Path.expand("../../../../docs/AGENT-WORKFLOW.md", __DIR__))

  defp from_ip(ip), do: %{build_conn() | remote_ip: ip}

  test "GET /api/v1/workflow.md without credentials: English by default", %{conn: conn} do
    conn = get(conn, "/api/v1/workflow.md")
    assert response(conn, 200) == @en
    assert ["text/markdown; charset=utf-8"] = get_resp_header(conn, "content-type")

    assert build_conn() |> get("/api/v1/workflow.md?lang=en") |> response(200) == @en
  end

  test "lang=zh is the Chinese workflow", %{conn: conn} do
    conn = get(conn, "/api/v1/workflow.md?lang=zh")
    assert response(conn, 200) == @zh
    assert ["text/markdown" <> _] = get_resp_header(conn, "content-type")
  end

  test "another language is 400 invalid_params", %{conn: conn} do
    body = conn |> get("/api/v1/workflow.md?lang=fr") |> json_response(400)
    assert %{"error" => "invalid_params", "detail" => %{"fields" => %{"lang" => [_]}}} = body
  end

  test "GET /api/v1/openapi.json without credentials", %{conn: conn} do
    spec = conn |> get("/api/v1/openapi.json") |> json_response(200)
    assert %{"openapi" => "3." <> _, "paths" => %{"/api/v1/w/{slug}/tasks/{id}" => _}} = spec
  end

  test "the 121st request of an IP in a minute is 429 with Retry-After" do
    put_rate_limits(public_api_ip: {120, :timer.minutes(1)})
    ip = unique_ip()

    for n <- 1..120 do
      path = if rem(n, 2) == 0, do: "/api/v1/workflow.md", else: "/api/v1/openapi.json"
      assert ip |> from_ip() |> get(path) |> Map.get(:status) == 200
    end

    conn = ip |> from_ip() |> get("/api/v1/workflow.md")
    assert %{"error" => "rate_limited"} = json_response(conn, 429)
    assert [retry_after] = get_resp_header(conn, "retry-after")
    assert String.to_integer(retry_after) > 0

    assert unique_ip() |> from_ip() |> get("/api/v1/workflow.md") |> response(200)
  end
end
