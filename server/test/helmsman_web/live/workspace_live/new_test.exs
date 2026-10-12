defmodule HelmsmanWeb.WorkspaceLive.NewTest do
  @moduledoc "Spec web-workspace-entry 新建工作区页."
  use HelmsmanWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Helmsman.AccountsFixtures
  import Helmsman.WorkspacesFixtures

  doctest HelmsmanWeb.WorkspaceLive.New

  setup %{conn: conn} do
    # The first user becomes the instance admin and owns the workspace `default`.
    _admin = user_fixture()
    user = user_fixture()
    workspace_fixture(user, %{name: "Mine"})
    %{conn: log_in_user(conn, user), user: user}
  end

  defp change(view, target, params) do
    view
    |> element("#new-workspace-form")
    |> render_change(Map.merge(%{"_target" => ["workspace", target]}, %{"workspace" => params}))
  end

  defp submit(view, params),
    do: view |> element("#new-workspace-form") |> render_submit(%{"workspace" => params})

  test "the slug follows the name", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/workspaces/new")
    change(view, "name", %{"name" => "Acme Inc.", "slug" => ""})
    assert has_element?(view, ~s(#workspace-slug[value="acme-inc"]))
  end

  test "a Chinese name leaves the slug empty and submitting asks for it", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/workspaces/new")
    change(view, "name", %{"name" => "海港", "slug" => ""})
    assert has_element?(view, ~s(#workspace-slug[value=""]))
    refute has_element?(view, "#workspace-slug-error")

    submit(view, %{"name" => "海港", "slug" => ""})
    assert has_element?(view, "#workspace-slug-error", "不能为空")
    assert has_element?(view, ~s(#workspace-name[value="海港"]))
  end

  test "a slug edited by hand no longer follows the name", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/workspaces/new")
    change(view, "name", %{"name" => "Acme", "slug" => ""})
    change(view, "slug", %{"name" => "Acme", "slug" => "acme-x"})
    change(view, "name", %{"name" => "Acme Labs", "slug" => "acme-x"})
    assert has_element?(view, ~s(#workspace-slug[value="acme-x"]))
  end

  test "format errors show while typing", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/workspaces/new")
    change(view, "slug", %{"name" => "", "slug" => "-bad"})
    assert has_element?(view, "#workspace-slug-error", "须为 2–39 位小写字母、数字或 -")
    refute has_element?(view, "#workspace-name-error")

    change(view, "name", %{"name" => String.duplicate("名", 81), "slug" => "-bad"})
    assert has_element?(view, "#workspace-name-error", "80")
  end

  test "creating enters the new workspace", %{conn: conn} do
    slug = unique_workspace_slug()
    {:ok, view, _html} = live(conn, ~p"/workspaces/new")

    {:ok, conn} =
      view
      |> element("#new-workspace-form")
      |> render_submit(%{"workspace" => %{"name" => "Acme", "slug" => slug}})
      |> follow_redirect(conn, "/w/#{slug}")

    assert html_response(conn, 200) =~ "工作区已创建"
    {:ok, view, _html} = live(conn, "/w/#{slug}")
    assert has_element?(view, "#hm-workspace-switcher-trigger", "Acme")
  end

  test "a taken slug is reported on submit and the input is kept", %{conn: conn} do
    other = workspace_fixture(user_fixture())
    {:ok, view, _html} = live(conn, ~p"/workspaces/new")

    change(view, "slug", %{"name" => "Acme", "slug" => other.slug})
    refute render(view) =~ "已被占用"

    submit(view, %{"name" => "Acme", "slug" => other.slug})
    assert has_element?(view, "#workspace-slug-error", "已被占用")
    assert has_element?(view, ~s(#workspace-name[value="Acme"]))
  end

  test "opened from the switcher; 取消 goes back", %{conn: conn, user: user} do
    [%{workspace: ws}] = Helmsman.Workspaces.list_for_user(user)
    {:ok, view, _html} = live(conn, "/w/#{ws.slug}")
    assert has_element?(view, ~s(#hm-ws-new[href="/workspaces/new"]))

    {:ok, view, _html} = live(conn, ~p"/workspaces/new")
    assert has_element?(view, ~s(#new-workspace-cancel[href="/"]))
    refute has_element?(view, "#new-workspace-intro")
  end

  test "users without a workspace see the intro and no 取消", %{conn: conn} do
    conn = log_in_user(conn, user_fixture())
    {:ok, view, _html} = live(conn, ~p"/workspaces/new")
    assert has_element?(view, "#new-workspace-intro", "创建你的第一个工作区")
    refute has_element?(view, "#new-workspace-cancel")
  end

  test "visitors are sent to log in" do
    assert {:error, {:redirect, %{to: "/users/log-in"}}} =
             live(Phoenix.ConnTest.build_conn(), ~p"/workspaces/new")
  end
end
