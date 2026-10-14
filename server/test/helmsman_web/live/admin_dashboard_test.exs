defmodule HelmsmanWeb.AdminDashboardTest do
  # server-release "管理面板与指标": LiveDashboard at /admin/dashboard for
  # instance administrators only. Sets environment variables.
  use HelmsmanWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Helmsman.AccountsFixtures

  setup do
    # The first user registered in a test is an instance administrator.
    admin = user_fixture()
    user = user_fixture()
    %{admin: admin, user: user}
  end

  test "an instance administrator gets the dashboard", %{conn: conn, admin: admin} do
    conn = log_in_user(conn, admin)

    page = get(conn, ~p"/admin/dashboard/home")
    html = html_response(page, 200)
    assert html =~ "Phoenix LiveDashboard"

    # Its inline bootstrap script runs under the CSP by a per-request nonce.
    [csp] = get_resp_header(page, "content-security-policy")
    [_, nonce] = Regex.run(~r/script-src 'self' 'nonce-([^']+)'/, csp)
    assert html =~ ~s(<script nonce="#{nonce}">)
    refute csp =~ "unsafe-inline' 'nonce"

    assert {:ok, _view, _html} = live(conn, ~p"/admin/dashboard/home")
  end

  test "a user who is not an instance administrator gets 404 (scenario)", %{
    conn: conn,
    user: user
  } do
    conn = log_in_user(conn, user)

    assert_error_sent 404, fn -> get(conn, ~p"/admin/dashboard/home") end
    assert_error_sent 404, fn -> get(conn, ~p"/admin/dashboard/metrics") end
  end

  test "without login: redirected to the login page", %{conn: conn} do
    conn = get(conn, ~p"/admin/dashboard/home")
    assert redirected_to(conn) == ~p"/users/log-in"
  end

  test "the home page shows only the listed variables, no secret", %{conn: conn, admin: admin} do
    vars = %{
      "PHX_URL_SCHEME" => "https",
      "HELMSMAN_LOG_FORMAT" => "json",
      "SECRET_KEY_BASE" => "dashboard-secret-marker",
      "HELMSMAN_VAULT_KEY" => "dashboard-vault-marker"
    }

    saved = Map.new(vars, fn {name, _} -> {name, System.get_env(name)} end)

    on_exit(fn ->
      Enum.each(saved, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end)

    System.put_env(vars)

    {:ok, _view, html} = conn |> log_in_user(admin) |> live(~p"/admin/dashboard/home")

    assert html =~ "PHX_URL_SCHEME"
    assert html =~ "HELMSMAN_LOG_FORMAT"
    refute html =~ "SECRET_KEY_BASE"
    refute html =~ "dashboard-secret-marker"
    refute html =~ "dashboard-vault-marker"
  end

  test "the metrics page lists Helmsman's metrics", %{conn: conn, admin: admin} do
    {:ok, _view, html} =
      conn |> log_in_user(admin) |> live(~p"/admin/dashboard/metrics?nav=helmsman")

    for metric <- ~w(helmsman.runs.queued.count helmsman.runs.claim.wait_ms
                     helmsman.runs.finished.count helmsman.daemons.online.count
                     helmsman.mcp.tool_call.duration) do
      assert html =~ metric
    end
  end
end
