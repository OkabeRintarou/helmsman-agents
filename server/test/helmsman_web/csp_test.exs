defmodule HelmsmanWeb.CspTest do
  # server-release "浏览器安全头" (add-release-distribution decision 7).
  # MCP requests run in session processes (shared sandbox): not async.
  use HelmsmanWeb.ConnCase, async: false

  import Helmsman.ApiTokensFixtures
  import Helmsman.ProjectsFixtures
  import Helmsman.WorkspacesFixtures

  setup :register_and_log_in_user

  defp directives(conn) do
    [csp] = get_resp_header(conn, "content-security-policy")

    for directive <- String.split(csp, ";", trim: true), into: %{} do
      [name | values] = directive |> String.trim() |> String.split(" ")
      {name, values}
    end
  end

  test "the task page has a CSP (scenario) and the other headers", %{conn: conn, user: user} do
    workspace = workspace_fixture(user)
    scope = workspace_scope_fixture(user, workspace)
    project = project_fixture(scope)
    task = task_fixture(scope, project.key)

    conn = get(conn, ~p"/w/#{workspace.slug}/t/#{task.ident}")
    assert html_response(conn, 200)

    csp = directives(conn)
    assert csp["script-src"] == ["'self'"]
    refute "'unsafe-inline'" in csp["script-src"]
    refute "'unsafe-eval'" in csp["script-src"]
    assert csp["frame-ancestors"] == ["'none'"]
    assert csp["default-src"] == ["'self'"]
    assert csp["object-src"] == ["'none'"]
    assert csp["base-uri"] == ["'self'"]
    assert csp["form-action"] == ["'self'", "https://github.com"]
    assert csp["img-src"] == ["'self'", "data:", "https:"]
    assert csp["style-src"] == ["'self'", "'unsafe-inline'"]
    assert ["'self'", "ws://" <> _] = csp["connect-src"]

    assert get_resp_header(conn, "referrer-policy") == ["strict-origin-when-cross-origin"]

    assert get_resp_header(conn, "permissions-policy") ==
             ["camera=(), microphone=(), geolocation=()"]
  end

  test "the connect-src WebSocket origin follows the public URL" do
    %URI{host: host, port: port} = HelmsmanWeb.Endpoint.struct_url()
    conn = get(build_conn(), ~p"/users/log-in")
    origin = if port in [80, nil], do: "ws://#{host}", else: "ws://#{host}:#{port}"
    assert directives(conn)["connect-src"] == ["'self'", origin]
  end

  test "pages without login have it too", %{conn: _conn} do
    conn = get(build_conn(), ~p"/users/log-in")
    assert directives(conn)["script-src"] == ["'self'"]
  end

  test "API, MCP, webhook and daemon JSON responses have no CSP", %{user: user} do
    workspace = workspace_fixture(user)
    %{token: token} = api_token_fixture(workspace_scope_fixture(user, workspace))

    responses = [
      build_conn() |> put_req_header("authorization", "Bearer " <> token) |> get("/api/v1/tasks"),
      build_conn()
      |> put_req_header("authorization", "Bearer " <> token)
      |> put_req_header("content-type", "application/json")
      |> post("/mcp", ~s({"jsonrpc":"2.0","id":1,"method":"ping"})),
      build_conn() |> put_req_header("content-type", "application/json") |> post("/mcp", "{}"),
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> post("/webhooks/github", "{}"),
      build_conn() |> post("/daemon/device/code", %{}),
      build_conn() |> get("/healthz"),
      build_conn() |> Map.put(:remote_ip, {10, 99, 0, 1}) |> get("/install.sh")
    ]

    for conn <- responses do
      assert get_resp_header(conn, "content-security-policy") == [], conn.request_path
      refute get_resp_header(conn, "permissions-policy") != [], conn.request_path
    end
  end
end
