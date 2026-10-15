defmodule HelmsmanWeb.TaskLive.ViewSwitchTest do
  use HelmsmanWeb.ConnCase, async: true
  import Phoenix.LiveViewTest
  import Helmsman.RunsFixtures
  import Helmsman.ProjectsFixtures
  alias Helmsman.ViewPrefs

  setup %{conn: conn} do
    ctx = dispatch_fixture()

    Map.merge(ctx, %{
      conn: log_in_user(conn, ctx.alice),
      base: "/w/#{ctx.workspace.slug}/p/#{ctx.project.key}"
    })
  end

  test "patch preserves filters and pid; workspace-wide preference and explicit URL precedence",
       ctx do
    task_fixture(ctx.alice_scope, ctx.project.key, %{labels: ["ui"]})
    {:ok, view, _} = live(ctx.conn, ctx.base <> "?label=ui")
    pid = view.pid
    assert has_element?(view, "#task-layout-list[aria-pressed=true]")
    view |> element("#task-layout-board") |> render_click()
    assert_patch(view, ctx.base <> "?label=ui&view=board")
    assert view.pid == pid
    assert has_element?(view, "#task-board")
    refute has_element?(view, "#tasks")
    project = project_fixture(ctx.alice_scope)
    {:ok, other, _} = live(ctx.conn, "/w/#{ctx.workspace.slug}/p/#{project.key}")
    assert has_element?(other, "#task-board")
    {:ok, explicit, _} = live(ctx.conn, ctx.base <> "?view=list")
    refute has_element?(explicit, "#task-board")
    assert {:ok, %{view: "board"}} = ViewPrefs.get(ctx.alice_scope)
    {:ok, invalid, _} = live(ctx.conn, ctx.base <> "?view=garbage")
    assert has_element?(invalid, "#task-board")
    view |> element("#task-layout-list") |> render_click()
    assert has_element?(view, "#tasks")
    refute has_element?(view, "#task-board")
    assert {:ok, %{view: "list"}} = ViewPrefs.get(ctx.alice_scope)
  end

  test "shared link does not save and preferences are per user", ctx do
    {:ok, link, _} = live(ctx.conn, ctx.base <> "?view=board")
    assert has_element?(link, "#task-board")
    {:ok, ordinary, _} = live(ctx.conn, ctx.base)
    refute has_element?(ordinary, "#task-board")
    ViewPrefs.put(ctx.alice_scope, %{view: "board"})
    {_user, viewer} = member_scope_fixture(ctx.workspace, :viewer)
    {:ok, other, _} = live(log_in_user(build_conn(), viewer.user), ctx.base)
    refute has_element?(other, "#task-board")
  end
end
