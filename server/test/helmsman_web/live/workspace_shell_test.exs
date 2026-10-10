defmodule HelmsmanWeb.WorkspaceShellTest do
  @moduledoc """
  The shell on real workspace pages (`/w/:slug`): workspaces come from
  `Helmsman.Workspaces.list_for_user/1` and membership changes (DR-8) are handled
  for the real scope.
  """
  use HelmsmanWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Helmsman.AccountsFixtures
  import Helmsman.WorkspacesFixtures

  alias HelmsmanWeb.Shell

  setup %{conn: conn} do
    user = user_fixture(%{display_name: "Alice"})
    acme = workspace_fixture(user, %{slug: "acme", name: "Acme"})

    other = user_fixture()
    beta = workspace_fixture(other, %{slug: "beta", name: "Beta"})
    member_fixture(beta, user, :member)
    hidden = workspace_fixture(other, %{slug: "hidden", name: "Hidden"})

    %{conn: log_in_user(conn, user), user: user, acme: acme, beta: beta, hidden: hidden}
  end

  test "renders the shell with the workspace and the user", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/w/acme")

    assert has_element?(view, "#hm-sidebar[aria-label=主导航]")
    assert has_element?(view, "#hm-workspace-switcher-trigger", "Acme")
    assert has_element?(view, "#hm-user-menu-trigger", "Alice")
    assert has_element?(view, "header h1", "Acme")
    assert has_element?(view, "#workspace-role", "owner")
  end

  test "the switcher lists the user's workspaces only, the current one checked",
       %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/w/acme")

    assert has_element?(view, ~s(#hm-ws-acme[aria-checked="true"]), "Acme")
    assert has_element?(view, ~s(#hm-ws-beta[aria-checked="false"]), "Beta")
    refute has_element?(view, "#hm-ws-hidden")
    assert has_element?(view, "#hm-ws-new", "新建工作区")
  end

  test "choosing another workspace goes to its home page", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/w/acme")
    view |> element("#hm-ws-beta") |> render_click()
    assert_redirect(view, "/w/beta")
  end

  test "workspaces the user does not belong to cannot be switched to", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/w/acme")
    render_click(view, "hm:switch-workspace", %{"slug" => "hidden"})
    refute_redirected(view)
  end

  describe "membership changes (DR-8) with the real scope" do
    test "removal from the current workspace leaves with a flash",
         %{conn: conn, user: user, beta: beta} do
      {:ok, view, _html} = live(conn, ~p"/w/beta")

      Phoenix.PubSub.broadcast(
        Helmsman.PubSub,
        Shell.topic(user.id),
        {:membership_changed, beta.id, :removed}
      )

      {path, flash} = assert_redirect(view)
      assert path == "/"
      assert flash["error"] == "你已被移出 Beta"
    end

    test "a role change re-mounts the current page", %{conn: conn, user: user, beta: beta} do
      {:ok, view, _html} = live(conn, ~p"/w/beta")

      Phoenix.PubSub.broadcast(
        Helmsman.PubSub,
        Shell.topic(user.id),
        {:membership_changed, beta.id, {:role, :viewer}}
      )

      assert_redirect(view, "/w/beta")
    end

    test "changes in other workspaces are ignored", %{conn: conn, user: user, acme: acme} do
      {:ok, view, _html} = live(conn, ~p"/w/beta")

      Phoenix.PubSub.broadcast(
        Helmsman.PubSub,
        Shell.topic(user.id),
        {:membership_changed, acme.id, :removed}
      )

      assert render(view) =~ "Beta"
      refute_redirected(view)
    end
  end
end
