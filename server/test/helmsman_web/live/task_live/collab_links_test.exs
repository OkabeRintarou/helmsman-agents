defmodule HelmsmanWeb.TaskLive.CollabLinksTest do
  # add-collaboration-ui 3.2, 3.3, 6.2: web-collaboration「关联区」「添加关联」and
  # 「他人添加关联」.
  use HelmsmanWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Helmsman.LinksFixtures
  import HelmsmanWeb.PortalHelpers

  alias Helmsman.{Feedback, Links, Tasks}

  @panel "link-panel"

  setup %{conn: conn} do
    ctx = links_fixture()
    tasks!(ctx.owner, "BOS", 2)
    tasks!(ctx.owner, "WEB", 3)
    Map.merge(ctx, %{conn: conn, slug: ctx.workspace.slug})
  end

  defp open(ctx, role, ident),
    do: live(log_in_user(ctx.conn, ctx[role].user), "/w/#{ctx.slug}/t/#{ident}")

  defp summary(ctx, ident) do
    {:ok, task} = Tasks.get(ctx.owner, ident)
    Tasks.summary(task)
  end

  defp open_panel(view) do
    view |> element("#task-links-add") |> render_click()
    assert open?(view, @panel)
  end

  defp picker(view) do
    cid = portal_attr(view, @panel, "[data-task-picker]", "data-phx-component")
    with_target(view, String.to_integer(cid))
  end

  defp relation(view, key),
    do: render_change(view, "collab_link_change", %{link: %{relation: key}})

  defp pick(view, ctx, ident) do
    id = portal_attr(view, @panel, "[data-task-picker]", "id")
    send(view.pid, {:task_picked, id, summary(ctx, ident)})
    render(view)
  end

  defp submit(view), do: render_submit(view, "collab_link_submit", %{})

  describe "关联区" do
    test "两个方向", ctx do
      {:ok, _} = Links.add(ctx.owner, "WEB-2", "BOS-1", "depends_on")

      {:ok, web, _} = open(ctx, :alice, "WEB-2")
      assert has_element?(web, "#task-links-depends-out #task-link-depends-out-BOS-1", "BOS-1")
      assert has_element?(web, "#task-link-depends-out-BOS-1", "在等：未完成")

      {:ok, bos, _} = open(ctx, :alice, "BOS-1")
      assert has_element?(bos, "#task-links-depends-in #task-link-depends-in-WEB-2")
      refute has_element?(bos, "#task-links-empty")
    end

    test "删除依赖", ctx do
      {:ok, _} = Links.add(ctx.owner, "WEB-2", "BOS-1", "depends_on")
      {:ok, view, _} = open(ctx, :alice, "WEB-2")
      assert has_element?(view, "#task-blocked")

      view |> element("#task-link-depends-out-BOS-1-remove") |> render_click()
      assert open?(view, "unlink-dialog")
      assert portal_text(view, "unlink-dialog", "#unlink-dialog-description") =~ "WEB-2 不再等 BOS-1"

      html =
        render_click(view, "collab_unlink", %{type: "depends_on", from: "WEB-2", to: "BOS-1"})

      assert html =~ "已删除关联"
      refute has_element?(view, "#task-link-depends-out-BOS-1")
      refute has_element?(view, "#task-blocked")
      assert has_element?(view, "#task-links-empty", "没有关联")
    end

    test "被替代的锁", ctx do
      {:ok, _} = Links.add(ctx.owner, "BOS-2", "BOS-1", "replaces")
      {:ok, view, _} = open(ctx, :alice, "BOS-1")
      assert has_element?(view, "#task-link-replaces-in-BOS-2 [data-locked]")
      assert has_element?(view, "#task-link-lock-BOS-2", "删除这条关联之前不能恢复")
    end

    test "viewer", ctx do
      {:ok, _} = Links.add(ctx.owner, "WEB-2", "BOS-1", "depends_on")
      {:ok, view, _} = open(ctx, :viewer, "WEB-2")
      assert has_element?(view, "#task-link-depends-out-BOS-1")
      refute has_element?(view, "#task-links-add")
      refute has_element?(view, "#task-link-depends-out-BOS-1-remove")
      render_click(view, "collab_link_open", %{})
      refute open?(view, @panel)
    end
  end

  describe "添加关联" do
    test "添加跨项目依赖 through the picker", ctx do
      {:ok, view, _} = open(ctx, :alice, "WEB-2")
      open_panel(view)

      render_change(picker(view), "search", %{"q" => "BOS-1"})
      assert in_portal?(view, @panel, "#link-picker-1-result-BOS-1")
      refute in_portal?(view, @panel, "#link-picker-1-result-WEB-2")
      render_click(picker(view), "pick", %{"task" => "BOS-1"})

      assert in_portal?(view, @panel, "#link-picker-1-selected[data-task=BOS-1]")
      assert portal_text(view, @panel, "#link-consequence") =~ "WEB-2 要等 BOS-1 满足"

      html = submit(view)
      assert html =~ "已添加关联"
      refute open?(view, @panel)
      assert has_element?(view, "#task-link-depends-out-BOS-1")
      assert has_element?(view, "#task-blocked")
    end

    test "替代进行中的任务", ctx do
      {:ok, _} = Tasks.transition(ctx.owner, "BOS-2", "in_progress")
      {:ok, view, _} = open(ctx, :alice, "BOS-1")
      open_panel(view)
      relation(view, "replaces-out")
      pick(view, ctx, "BOS-2")

      assert portal_attr(view, @panel, "#link-consequence", "data-tone") == "warning"
      assert portal_text(view, @panel, "#link-consequence") =~ "BOS-2 现在是进行中，建立后会被自动撤销"

      submit(view)
      assert has_element?(view, "#task-links-replaces-out #task-link-replaces-out-BOS-2")
      assert status_of(%{id: summary_id(ctx, "BOS-2")}) == :cancelled
    end

    test "被依赖方向", ctx do
      {:ok, view, _} = open(ctx, :alice, "BOS-1")
      open_panel(view)
      relation(view, "depends-in")
      pick(view, ctx, "WEB-3")
      submit(view)

      assert has_element?(view, "#task-link-depends-in-WEB-3")
      assert Links.blockers(summary_id(ctx, "WEB-3")) == ["BOS-1"]
    end

    test "成环", ctx do
      {:ok, _} = Links.add(ctx.owner, "BOS-2", "BOS-1", "depends_on")
      {:ok, view, _} = open(ctx, :alice, "BOS-1")
      open_panel(view)
      pick(view, ctx, "BOS-2")
      submit(view)

      assert open?(view, @panel)
      assert portal_text(view, @panel, "#link-panel-error") =~ "会形成循环：BOS-1 → BOS-2 → BOS-1"
      refute has_element?(view, "#task-link-depends-out-BOS-2")
    end

    test "a task that is gone meanwhile", ctx do
      {:ok, view, _} = open(ctx, :alice, "BOS-1")
      open_panel(view)
      id = portal_attr(view, @panel, "[data-task-picker]", "id")
      send(view.pid, {:task_picked, id, %{summary(ctx, "BOS-2") | id: "BOS-99"}})
      submit(view)
      assert portal_text(view, @panel, "#link-panel-error") =~ "任务 BOS-99 不存在"
    end

    test "the picker never offers the task itself or existing links", ctx do
      {:ok, _} = Links.add(ctx.owner, "BOS-1", "BOS-2", "depends_on")
      {:ok, view, _} = open(ctx, :alice, "BOS-1")
      open_panel(view)
      render_change(picker(view), "search", %{"q" => "BOS"})
      refute in_portal?(view, @panel, "#link-picker-1-result-BOS-1")
      refute in_portal?(view, @panel, "#link-picker-1-result-BOS-2")
    end
  end

  test "他人添加关联", ctx do
    {:ok, view, _} = open(ctx, :alice, "WEB-2")
    view |> element("#feedback-add") |> render_click()
    session = portal_attr(view, "feedback-panel", "input[name=editor_session]", "value")
    render_change(view, "feedback_change", %{feedback: %{content: "草稿"}, editor_session: session})

    {:ok, _} = Links.add(ctx.owner, "WEB-2", "BOS-2", "depends_on")

    assert has_element?(view, "#task-link-depends-out-BOS-2")
    assert has_element?(view, "#task-blocked")
    assert open?(view, "feedback-panel")
    assert Feedback.list(ctx.alice, "WEB-2") == {:ok, []}
  end

  defp summary_id(ctx, ident) do
    {:ok, task} = Tasks.get(ctx.owner, ident)
    task.id
  end
end
