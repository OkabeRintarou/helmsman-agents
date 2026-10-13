defmodule HelmsmanWeb.ShellTest do
  use HelmsmanWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias HelmsmanWeb.Shell

  setup %{conn: conn} do
    user_id = "user-#{System.unique_integer([:positive])}"
    {:ok, conn: Plug.Test.init_test_session(conn, dev_ui_user_id: user_id), user_id: user_id}
  end

  describe "layout" do
    test "sidebar structure and skip link", %{conn: conn} do
      {:ok, view, html} = live(conn, "/dev/ui/projects")

      assert has_element?(view, "#hm-sidebar[aria-label=主导航]")
      assert has_element?(view, "#hm-workspace-switcher-trigger", "acme")
      assert has_element?(view, "#hm-search-entry", "搜索")
      assert has_element?(view, "#hm-new-task[data-hm-new-task]", "新建任务")
      assert has_element?(view, "#hm-nav-my_work", "我的工作")
      assert has_element?(view, "#hm-nav-projects", "项目")
      refute has_element?(view, "#hm-nav-agents")
      refute html =~ "小队"
      assert has_element?(view, "#hm-user-menu-trigger", "Alice")
      assert has_element?(view, "header h1", "项目")

      [skip_at] = :binary.matches(html, ~s(href="#hm-main")) |> Enum.map(&elem(&1, 0))
      [sidebar_at] = :binary.matches(html, ~s(id="hm-sidebar")) |> Enum.map(&elem(&1, 0))
      assert skip_at < sidebar_at
      assert html =~ "跳到主要内容"
      assert has_element?(view, "main#hm-main")
    end

    test "only the current navigation item has aria-current", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/dev/ui/projects")

      assert has_element?(view, ~s(#hm-sidebar a[aria-current="page"]), "查看全部")
      refute has_element?(view, ~s(#hm-sidebar a[aria-current="page"]), "组件陈列")

      {:ok, view, _html} = live(conn, "/dev/ui")
      assert has_element?(view, ~s(#hm-sidebar a[aria-current="page"]), "组件陈列")
    end

    test "the auth layout is a centered card without the sidebar" do
      html =
        Phoenix.LiveViewTest.render_component(&HelmsmanWeb.Layouts.auth/1,
          flash: %{},
          title: "登录",
          inner_block: [%{inner_block: fn _, _ -> "form" end}]
        )

      assert html =~ "登录"
      assert html =~ "max-w-[400px]"
      refute html =~ "hm-sidebar"
    end

    test "page title carries the workspace suffix", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/dev/ui/projects")
      assert page_title(view) == "项目 · acme"
    end
  end

  describe "new task entry" do
    test "adds ?panel=new to the current URL and closing keeps the filters", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/dev/ui?label=api&q=x&status=new%2Cin_progress")

      assert view |> element("#hm-new-task") |> render() =~
               "/dev/ui?label=api&amp;panel=new&amp;q=x&amp;status=new%2Cin_progress"

      render_patch(view, "/dev/ui?label=api&panel=new&q=x&status=new%2Cin_progress")
      panel = view |> element("#demo-panel-portal") |> render()

      assert panel =~
               ~r/data-cancel="\[\[&quot;patch&quot;,\{[^}]*&quot;href&quot;:&quot;\/dev\/ui\?label=api&amp;q=x&amp;status=new%2Cin_progress&quot;/

      render_submit(view, "save_panel", %{task: %{title: "t", note: ""}})
      assert_patch(view, "/dev/ui?label=api&q=x&status=new%2Cin_progress")
      assert has_element?(view, "#demo-filters-chip-label")
    end
  end

  describe "workspace switcher and user menu" do
    test "lists the workspaces with the current one checked", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/dev/ui")

      assert has_element?(view, ~s(#hm-ws-acme[aria-checked="true"]), "acme")
      assert has_element?(view, ~s(#hm-ws-beta[aria-checked="false"]), "beta")
      assert has_element?(view, "#hm-ws-new", "新建工作区")
    end

    test "choosing another workspace goes to its home page", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/dev/ui")
      view |> element("#hm-ws-beta") |> render_click()
      assert_redirect(view, "/w/beta")
    end

    test "a single workspace lists only itself and the create entry", %{conn: conn} do
      conn = Plug.Test.init_test_session(conn, dev_ui_workspaces: ["acme"])
      {:ok, view, _html} = live(conn, "/dev/ui")

      assert has_element?(view, ~s(#hm-ws-acme[aria-checked="true"]))
      refute has_element?(view, "#hm-ws-beta")
      assert has_element?(view, "#hm-ws-new")
    end

    test "unknown workspaces are ignored", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/dev/ui")
      render_click(view, "hm:switch-workspace", %{"slug" => "evil"})
      refute_redirected(view)
    end

    test "user menu: account settings, theme options and log out", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/dev/ui")

      assert has_element?(view, ~s(#hm-account[href="/users/settings"]), "账号设置")

      assert has_element?(
               view,
               ~s(#hm-provider-accounts[href="/users/settings/provider-accounts"]),
               "供应商账号"
             )

      for theme <- ~w(system light dark) do
        assert has_element?(
                 view,
                 ~s(#hm-theme-#{theme}[data-theme-option="#{theme}"][role="menuitemradio"])
               )
      end

      assert has_element?(
               view,
               ~s(#hm-log-out[href="/users/log-out"][data-method="delete"]),
               "退出登录"
             )
    end
  end

  describe "membership changes (DR-8)" do
    test "removal from the current workspace leaves with a flash", %{conn: conn, user_id: user_id} do
      {:ok, view, _html} = live(conn, "/dev/ui/projects")

      Phoenix.PubSub.broadcast(
        Helmsman.PubSub,
        Shell.topic(user_id),
        {:membership_changed, "ws-acme", :removed}
      )

      {path, flash} = assert_redirect(view)
      assert path == "/"
      assert flash["error"] == "你已被移出 acme"
    end

    test "a role change re-mounts the current page", %{conn: conn, user_id: user_id} do
      {:ok, view, _html} = live(conn, "/dev/ui/projects?tab=tokens")

      Phoenix.PubSub.broadcast(
        Helmsman.PubSub,
        Shell.topic(user_id),
        {:membership_changed, "ws-acme", {:role, :viewer}}
      )

      assert_redirect(view, "/dev/ui/projects?tab=tokens")
    end

    test "changes in other workspaces are ignored", %{conn: conn, user_id: user_id} do
      {:ok, view, _html} = live(conn, "/dev/ui")

      Phoenix.PubSub.broadcast(
        Helmsman.PubSub,
        Shell.topic(user_id),
        {:membership_changed, "ws-beta", :removed}
      )

      Phoenix.PubSub.broadcast(
        Helmsman.PubSub,
        Shell.topic(user_id),
        {:membership_changed, "ws-beta", {:role, :admin}}
      )

      assert render(view) =~ "组件陈列"
      refute_redirected(view)
    end
  end
end
