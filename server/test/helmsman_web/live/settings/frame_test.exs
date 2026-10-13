defmodule HelmsmanWeb.SettingsLive.FrameTest do
  @moduledoc "Spec web-workspace-settings 设置入口与标签页."
  use HelmsmanWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Helmsman.AccountsFixtures
  import Helmsman.WorkspacesFixtures

  setup %{conn: conn} do
    _admin = user_fixture()
    owner = user_fixture()
    ws = workspace_fixture(owner, %{name: "Acme"})
    viewer = user_fixture()
    member_fixture(ws, viewer, :viewer)
    %{conn: log_in_user(conn, viewer), ws: ws}
  end

  test "a viewer opens the settings from the sidebar", %{conn: conn, ws: ws} do
    {:ok, view, _html} = live(conn, "/w/#{ws.slug}")

    {:ok, view, _html} =
      view
      |> element(~s(#hm-sidebar a[href="/w/#{ws.slug}/settings"]), "设置")
      |> render_click()
      |> follow_redirect(conn, "/w/#{ws.slug}/settings")

    assert has_element?(
             view,
             ~s(header nav[aria-label="面包屑"] a[href="/w/#{ws.slug}/settings"]),
             "设置"
           )

    assert has_element?(view, "header h1", "常规")
    assert page_title(view) == "常规 · Acme"

    for {label, path} <- [
          {"常规", ""},
          {"成员", "/members"},
          {"API Token", "/tokens"},
          {"GitHub", "/github"}
        ] do
      assert has_element?(
               view,
               ~s(nav[aria-label="设置"] a[href="/w/#{ws.slug}/settings#{path}"]),
               label
             )
    end

    assert has_element?(view, ~s(nav[aria-label="设置"] a[aria-current="page"]), "常规")
    assert has_element?(view, ~s(#hm-sidebar a[aria-current="page"]), "设置")
  end

  test "switching tabs keeps 设置 highlighted", %{conn: conn, ws: ws} do
    {:ok, view, _html} = live(conn, "/w/#{ws.slug}/settings")

    {:ok, view, _html} =
      view
      |> element(~s(nav[aria-label="设置"] a), "成员")
      |> render_click()
      |> follow_redirect(conn, "/w/#{ws.slug}/settings/members")

    assert page_title(view) =~ "成员"
    assert has_element?(view, "header h1", "成员")
    assert has_element?(view, ~s(nav[aria-label="设置"] a[aria-current="page"]), "成员")
    assert has_element?(view, ~s(#hm-sidebar a[aria-current="page"]), "设置")

    {:ok, _view, html} = live(conn, "/w/#{ws.slug}/settings/members")
    assert html =~ "<title" and html =~ "成员 · Acme</title>"
  end
end
