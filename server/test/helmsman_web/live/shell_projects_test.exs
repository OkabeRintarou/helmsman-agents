defmodule HelmsmanWeb.ShellProjectsTest do
  @moduledoc """
  The shell's 项目 group, new-task entry and workspace subscription
  (add-projects-tasks-ui D2/D3/D10; add-workspace-settings-ui D8, implemented here).
  """
  use HelmsmanWeb.ConnCase, async: true

  import ExUnit.CaptureLog
  import Phoenix.LiveViewTest
  import Helmsman.AccountsFixtures
  import Helmsman.ProjectsFixtures
  import Helmsman.WorkspacesFixtures

  alias Helmsman.{Events, Projects}

  setup %{conn: conn} do
    owner = user_fixture()
    ws = workspace_fixture(owner, %{name: "Acme"})
    owner_scope = workspace_scope_fixture(owner, ws)
    member = user_fixture()
    member_fixture(ws, member, :member)
    viewer = user_fixture()
    member_fixture(ws, viewer, :viewer)

    project_fixture(owner_scope, key: "BOS", name: "Bosun")
    project_fixture(owner_scope, key: "BOSX", name: "Bosun X")
    task_fixture(owner_scope, "BOS")
    task_fixture(owner_scope, "BOS")
    task_fixture(owner_scope, "BOS")

    %{conn: log_in_user(conn, member), ws: ws, slug: ws.slug, owner: owner_scope, viewer: viewer}
  end

  defp nav(_view, key), do: ~s(#hm-nav-projects a[href$="/p/#{key}"])

  test "the project of a task page is highlighted", %{conn: conn, slug: slug} do
    {:ok, view, _html} = live(conn, "/w/#{slug}/t/BOS-3")

    assert has_element?(view, nav(view, "BOS") <> ~s([aria-current="page"]), "Bosun")
    assert has_element?(view, nav(view, "BOS") <> ~s([aria-label="Bosun（BOS）"]))
    refute has_element?(view, nav(view, "BOSX") <> "[aria-current]")
    refute has_element?(view, ~s(#hm-nav-projects a[href$="/projects"][aria-current]))

    assert [_] =
             view
             |> render()
             |> LazyHTML.from_fragment()
             |> LazyHTML.query("[aria-current=page]")
             |> Enum.to_list()
  end

  test "查看全部 comes last and is current on the projects page", %{conn: conn, slug: slug} do
    {:ok, view, _html} = live(conn, "/w/#{slug}/projects")

    hrefs =
      view
      |> element("#hm-nav-projects")
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("a")
      |> LazyHTML.attribute("href")

    assert hrefs == ["/w/#{slug}/p/BOS", "/w/#{slug}/p/BOSX", "/w/#{slug}/projects"]
    assert has_element?(view, ~s(#hm-nav-projects a[href$="/projects"][aria-current="page"]))
  end

  test "projects created, renamed or archived elsewhere update the sidebar in place",
       %{conn: conn, slug: slug, owner: owner} do
    {:ok, view, _html} = live(conn, "/w/#{slug}/t/BOS-3")
    pid = view.pid

    project_fixture(owner, key: "API", name: "Api")
    assert has_element?(view, nav(view, "API"), "Api")

    {:ok, _} = Projects.update(owner, "API", %{name: "Api 2"})
    assert has_element?(view, nav(view, "API"), "Api 2")

    {:ok, _} = Projects.archive(owner, "BOSX")
    refute has_element?(view, nav(view, "BOSX"))

    {:ok, _} = Projects.unarchive(owner, "BOSX")
    assert has_element?(view, nav(view, "BOSX"))
    assert view.pid == pid
    assert Process.alive?(pid)
  end

  test "viewers have no new-task entry", %{conn: conn, slug: slug, viewer: viewer} do
    {:ok, view, _html} = live(log_in_user(conn, viewer), "/w/#{slug}/projects")
    refute has_element?(view, "[data-hm-new-task]")

    {:ok, member_view, _html} = live(conn, "/w/#{slug}/projects")
    assert has_element?(member_view, "[data-hm-new-task]")
  end

  describe "workspace topic (add-workspace-settings-ui D8)" do
    defp broadcast(ws, message),
      do: Phoenix.PubSub.broadcast(Helmsman.PubSub, Events.topic(:workspace, ws.id), message)

    test "a rename updates the switcher without re-mounting", %{conn: conn, ws: ws, slug: slug} do
      {:ok, view, _html} = live(conn, "/w/#{slug}/projects")
      pid = view.pid

      broadcast(ws, {:workspace_updated, %{id: ws.id, name: "Acme 中国", slug: slug}})

      assert has_element?(view, "#hm-workspace-switcher-trigger", "Acme 中国")
      assert has_element?(view, "#hm-ws-#{slug}", "Acme 中国")
      # The title suffix is in the root layout; app.js swaps it on this event.
      assert_push_event(view, "hm:title-suffix", %{suffix: " · Acme 中国"})
      assert view.pid == pid
      refute_redirected(view)
    end

    test "a rename on a settings page (spec web-app-shell 工作区改名)",
         %{conn: conn, ws: ws, slug: slug} do
      {:ok, view, _html} = live(conn, "/w/#{slug}/settings/members")
      assert page_title(view) == "成员 · Acme"
      pid = view.pid

      broadcast(ws, {:workspace_updated, %{id: ws.id, name: "Acme 中国", slug: slug}})

      assert has_element?(view, "#hm-workspace-switcher-trigger", "Acme 中国")
      assert_push_event(view, "hm:title-suffix", %{suffix: " · Acme 中国"})
      assert view.pid == pid
      refute_redirected(view)
    end

    test "a slug change keeps the settings page and its query",
         %{conn: conn, ws: ws, slug: slug} do
      {:ok, view, _html} = live(conn, "/w/#{slug}/settings/tokens?panel=new-token")

      broadcast(ws, {:workspace_updated, %{id: ws.id, name: "Acme", slug: "acme-cn"}})

      {path, flash} = assert_redirect(view)
      assert path == "/w/acme-cn/settings/tokens?panel=new-token"
      assert flash["info"] == "工作区地址已改为 /w/acme-cn"
    end

    test "a slug change moves to the same page under the new slug",
         %{conn: conn, ws: ws, slug: slug} do
      {:ok, view, _html} = live(conn, "/w/#{slug}/p/BOS?status=new")

      broadcast(ws, {:workspace_updated, %{id: ws.id, name: "Acme", slug: "acme-cn"}})

      {path, flash} = assert_redirect(view)
      assert path == "/w/acme-cn/p/BOS?status=new"
      assert flash["info"] == "工作区地址已改为 /w/acme-cn"
    end

    test "messages are forwarded only to pages that handle them",
         %{conn: conn, ws: ws, slug: slug} do
      {:ok, home, _html} = live(conn, "/w/#{slug}")
      {:ok, list, _html} = live(conn, "/w/#{slug}/p/BOS")

      log =
        capture_log(fn ->
          broadcast(ws, {:members_changed})
          broadcast(ws, {:unknown_event, 1})
          render(home)
          render(list)
        end)

      refute log =~ "undefined handle_info"
      assert Process.alive?(home.pid)
      assert Process.alive?(list.pid)
    end
  end
end
