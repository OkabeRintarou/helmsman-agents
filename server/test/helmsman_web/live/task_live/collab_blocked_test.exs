defmodule HelmsmanWeb.TaskLive.CollabBlockedTest do
  # add-collaboration-ui 2.1–2.3, 6.2: web-collaboration「被阻塞的标记与开始」and the
  # unblocking part of「协作信息的实时刷新」.
  use HelmsmanWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Helmsman.LinksFixtures

  alias Helmsman.{Links, Tasks}

  setup %{conn: conn} do
    ctx = links_fixture()
    [bos1] = tasks!(ctx.owner, "BOS", 1)
    [web1] = tasks!(ctx.owner, "WEB", 1)
    slug = ctx.workspace.slug
    Map.merge(ctx, %{conn: conn, bos1: bos1, web1: web1, slug: slug})
  end

  defp open(ctx, role, ident),
    do: live(log_in_user(ctx.conn, ctx[role].user), "/w/#{ctx.slug}/t/#{ident}")

  defp tip(view), do: view |> element("#task-blocked-tip") |> render()

  test "被阻塞的新任务", ctx do
    {:ok, _} = Tasks.transition(ctx.owner, "BOS-1", "in_progress")
    {:ok, _} = Links.add(ctx.owner, "WEB-1", "BOS-1", "depends_on")

    {:ok, view, _} = open(ctx, :alice, "WEB-1")

    assert has_element?(view, ~s(#task-blocked[href="#task-links"]), "被阻塞")
    assert tip(view) =~ "BOS-1 未完成"
    assert has_element?(view, "#transition-in_progress[aria-disabled=true]")
    assert render(view) =~ "被 BOS-1 阻塞，前置任务满足后才能开始"

    assert has_element?(
             view,
             ~s(#task-link-depends-out-BOS-1[data-waiting-for="status"]),
             "在等：未完成"
           )
  end

  test "竞态中被拒", ctx do
    {:ok, view, _} = open(ctx, :alice, "WEB-1")
    refute has_element?(view, "#task-blocked")
    {:ok, _} = Links.add(ctx.owner, "WEB-1", "BOS-1", "depends_on")

    # The click was rendered before the link existed.
    html = render_click(view, "transition", %{to: "in_progress", from: "new"})
    assert html =~ "被 BOS-1 阻塞（前置任务还没满足），不能开始"
    assert status_of(ctx.web1) == :new
  end

  test "被替代后恢复, and the race", ctx do
    {:ok, _} = Links.add(ctx.owner, "WEB-1", "BOS-1", "replaces")
    assert status_of(ctx.bos1) == :cancelled

    {:ok, view, _} = open(ctx, :alice, "BOS-1")
    assert has_element?(view, "#transition-new[aria-disabled=true]")
    assert render(view) =~ "已被 WEB-1 替代；先在关联中删除替代关联，才能恢复"
    assert has_element?(view, "#task-link-replaces-in-WEB-1 [data-locked]")

    [web2] = tasks!(ctx.owner, "WEB", 1)
    {:ok, _} = Links.remove(ctx.owner, "WEB-1", "BOS-1", "replaces")
    {:ok, view, _} = open(ctx, :alice, "BOS-1")
    refute has_element?(view, "#transition-new[aria-disabled]")
    {:ok, _} = Links.add(ctx.owner, web2.ident, "BOS-1", "replaces")

    html = render_click(view, "transition", %{to: "new", from: "cancelled"})
    assert html =~ "已被 WEB-2 替代；先在关联中删除替代关联，才能恢复"
    assert status_of(ctx.bos1) == :cancelled
  end

  test "列表图标", ctx do
    {:ok, _} = Links.add(ctx.owner, "WEB-1", "BOS-1", "depends_on")
    [_web2] = tasks!(ctx.owner, "WEB", 1)

    {:ok, view, _} = live(log_in_user(ctx.conn, ctx.alice.user), "/w/#{ctx.slug}/p/WEB")
    assert has_element?(view, "#tasks [data-blocked]")
    blocked = view |> element("#tasks") |> render() |> LazyHTML.from_fragment()
    assert blocked |> LazyHTML.query("[data-blocked]") |> Enum.count() == 1
  end

  test "前置任务完成后解除阻塞（实时）", ctx do
    {:ok, _} = Links.add(ctx.owner, "WEB-1", "BOS-1", "depends_on")
    {:ok, view, _} = open(ctx, :alice, "WEB-1")
    {:ok, list, _} = live(log_in_user(ctx.conn, ctx.alice.user), "/w/#{ctx.slug}/p/WEB")
    assert has_element?(view, "#task-blocked")
    assert has_element?(list, "#tasks [data-blocked]")

    {:ok, _} = Tasks.transition(ctx.owner, "BOS-1", "in_progress")
    {:ok, _} = Tasks.transition(ctx.owner, "BOS-1", "done")

    refute has_element?(view, "#task-blocked")
    refute has_element?(view, "#transition-in_progress[aria-disabled]")
    assert has_element?(view, "#task-link-depends-out-BOS-1 [data-satisfied]", "已满足")
    refute has_element?(list, "#tasks [data-blocked]")
  end
end
