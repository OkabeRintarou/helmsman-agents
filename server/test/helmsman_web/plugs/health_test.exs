defmodule HelmsmanWeb.Plugs.HealthTest do
  # Stops and restarts the application's Oban instance.
  use HelmsmanWeb.ConnCase, async: false

  import ExUnit.CaptureLog

  alias Ecto.Adapters.SQL.Sandbox

  defp version, do: :helmsman |> Application.spec(:vsn) |> to_string()

  defp with_debug_log(fun) do
    level = Logger.level()
    Logger.configure(level: :debug)

    try do
      capture_log([level: :debug], fun)
    after
      Logger.configure(level: level)
    end
  end

  test "GET /healthz is 200 without touching the database", %{conn: conn} do
    # No sandbox connection: any query would fail.
    Sandbox.mode(Helmsman.Repo, :manual)

    conn = get(conn, "/healthz")
    assert json_response(conn, 200) == %{"status" => "ok"}
  end

  test "GET /readyz is 200 with the version and both checks", %{conn: conn} do
    conn = get(conn, "/readyz")

    assert json_response(conn, 200) == %{
             "status" => "ok",
             "version" => version(),
             "checks" => %{"database" => "ok", "oban" => "ok"}
           }

    assert get_resp_header(conn, "cache-control") == ["no-store"]
  end

  test "HEAD /healthz and /readyz answer like GET", %{conn: conn} do
    assert conn |> head("/healthz") |> response(200)
    assert recycle(conn) |> head("/readyz") |> response(200)
  end

  test "database unavailable (scenario): /readyz 503 with checks.database error, /healthz 200",
       %{conn: conn} do
    # Leaves shared mode: the request can no longer reach the database.
    Sandbox.mode(Helmsman.Repo, :manual)

    readyz = get(conn, "/readyz")
    body = json_response(readyz, 503)
    assert body["status"] == "error"
    assert body["checks"] == %{"database" => "error", "oban" => "ok"}
    # No error details.
    assert Map.keys(body) |> Enum.sort() == ["checks", "status", "version"]
    refute readyz.resp_body =~ ~r/ownership|DBConnection|Postgrex/i

    assert recycle(conn) |> get("/healthz") |> json_response(200) == %{"status" => "ok"}
  end

  test "Oban stopped: /readyz 503 with checks.oban error", %{conn: conn} do
    :ok = Supervisor.terminate_child(Helmsman.Supervisor, Oban)
    on_exit(fn -> {:ok, _pid} = Supervisor.restart_child(Helmsman.Supervisor, Oban) end)

    body = conn |> get("/readyz") |> json_response(503)
    assert body["checks"] == %{"database" => "ok", "oban" => "error"}
  end

  test "POST /healthz is not handled by the plug: it reaches the router", %{conn: conn} do
    for path <- ["/healthz", "/readyz"] do
      conn = post(recycle(conn), path)
      assert conn.status == 404
      refute conn.resp_body =~ ~s("status":"ok")
    end
  end

  test "health checks write no request log line; other requests do", %{conn: conn} do
    log =
      with_debug_log(fn ->
        get(conn, "/healthz")
        get(build_conn(), "/readyz")
      end)

    refute log =~ "/healthz"
    refute log =~ "/readyz"
    refute log =~ "Sent 200"

    assert with_debug_log(fn -> get(build_conn(), "/users/log-in") end) =~ "GET /users/log-in"
  end
end
