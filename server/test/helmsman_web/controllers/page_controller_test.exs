defmodule HelmsmanWeb.PageControllerTest do
  @moduledoc "`/` redirects (spec web-workspace-entry 根路径跳转)."
  use HelmsmanWeb.ConnCase, async: true

  import Helmsman.AccountsFixtures
  import Helmsman.WorkspacesFixtures

  alias Helmsman.Members

  setup do
    # The first user becomes the instance admin and owns the workspace `default`.
    _admin = user_fixture()
    user = user_fixture()
    other = user_fixture()
    acme = workspace_fixture(other, %{name: "Acme"})
    beta = workspace_fixture(other, %{name: "Beta"})
    acme_m = member_fixture(acme, user, :member)
    beta_m = member_fixture(beta, user, :member)

    %{user: user, other: other, acme: acme, beta: beta, acme_m: acme_m, beta_m: beta_m}
  end

  test "goes back to the most recently visited workspace", %{conn: conn, user: user, beta: beta} do
    conn = conn |> log_in_user(user) |> get("/w/#{beta.slug}/settings")
    conn = get(recycle(conn), ~p"/")
    assert redirected_to(conn) == "/w/#{beta.slug}"
  end

  test "a remembered workspace the user left is skipped",
       %{conn: conn, user: user, other: other, acme: acme, beta: beta, beta_m: beta_m} do
    conn = conn |> log_in_user(user) |> get("/w/#{beta.slug}")
    {:ok, _} = Members.remove(workspace_scope_fixture(other, beta), beta_m.id)

    conn = get(recycle(conn), ~p"/")
    assert redirected_to(conn) == "/w/#{acme.slug}"
  end

  test "without a remembered workspace the first by name is used",
       %{conn: conn, user: user, acme: acme} do
    conn = conn |> log_in_user(user) |> get(~p"/")
    assert redirected_to(conn) == "/w/#{acme.slug}"
  end

  test "users without workspaces go to /workspaces/new", %{conn: conn} do
    conn = conn |> log_in_user(user_fixture()) |> get(~p"/")
    assert redirected_to(conn) == ~p"/workspaces/new"
  end

  test "visitors go to the log-in page", %{conn: conn} do
    assert redirected_to(get(conn, ~p"/")) == ~p"/users/log-in"
  end

  # The flash the shell's redirect to `/` carries arrives in the session.
  test "a flash survives the redirect", %{conn: conn, user: user, acme: acme} do
    conn =
      conn
      |> log_in_user(user)
      |> put_session("phoenix_flash", %{"error" => "你已被移出 Beta"})
      |> get(~p"/")

    assert redirected_to(conn) == "/w/#{acme.slug}"

    conn = get(recycle(conn), "/w/#{acme.slug}")
    assert Phoenix.Flash.get(conn.assigns.flash, :error) == "你已被移出 Beta"
    assert html_response(conn, 200) =~ "你已被移出 Beta"
  end
end
