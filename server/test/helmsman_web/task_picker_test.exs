defmodule HelmsmanWeb.TaskPickerTest do
  # add-collaboration-ui 3.1: the task picker (D6), through the panels of the task page.
  use HelmsmanWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Helmsman.LinksFixtures
  import Helmsman.ProjectsFixtures
  import HelmsmanWeb.PortalHelpers

  setup %{conn: conn} do
    ctx = links_fixture()
    task_fixture(ctx.owner, "BOS", %{title: "支付回调重试"})
    task_fixture(ctx.owner, "BOS", %{title: "登录页", kind: "epic"})
    task_fixture(ctx.owner, "WEB", %{title: "前端目标", kind: "epic"})
    task_fixture(ctx.owner, "WEB", %{title: "首页"})
    {:ok, view, _} = live(log_in_user(conn, ctx.alice.user), "/w/#{ctx.workspace.slug}/t/WEB-2")
    Map.put(ctx, :view, view)
  end

  defp picker(view, panel) do
    cid = portal_attr(view, panel, "[data-task-picker]", "data-phx-component")
    with_target(view, String.to_integer(cid))
  end

  defp results(view, panel),
    do:
      view
      |> portal(panel)
      |> LazyHTML.query("[data-task-picker] [role=listbox] button")
      |> LazyHTML.attribute("id")
      |> Enum.map(&(&1 |> String.split("-result-") |> List.last()))

  test "searches by ID and by title, never the task itself", %{view: view} do
    view |> element("#task-links-add") |> render_click()
    assert results(view, "link-panel") == []

    render_change(picker(view, "link-panel"), "search", %{"q" => "BOS-1"})
    assert hd(results(view, "link-panel")) == "BOS-1"

    render_change(picker(view, "link-panel"), "search", %{"q" => "支付"})
    assert results(view, "link-panel") == ["BOS-1"]

    render_change(picker(view, "link-panel"), "search", %{"q" => "首页"})
    assert results(view, "link-panel") == []
    assert in_portal?(view, "link-panel", "[id$=-none]", "没有匹配的任务")
  end

  test "Enter picks the first result; clearing tells the page", %{view: view} do
    view |> element("#task-links-add") |> render_click()
    render_change(picker(view, "link-panel"), "search", %{"q" => "支付"})
    render_submit(picker(view, "link-panel"), "pick_first", %{"q" => "支付"})

    assert in_portal?(view, "link-panel", "[id$=-selected][data-task=BOS-1]")
    assert :sys.get_state(view.pid).socket.assigns.collab.link_panel.picked.id == "BOS-1"

    render_click(picker(view, "link-panel"), "clear", %{})
    assert :sys.get_state(view.pid).socket.assigns.collab.link_panel.picked == nil
    assert portal_attr(view, "link-panel", "#link-submit", "disabled") != nil
  end

  test "an invalid query says so", %{view: view} do
    view |> element("#task-links-add") |> render_click()
    render_change(picker(view, "link-panel"), "search", %{"q" => String.duplicate("长", 250)})
    assert in_portal?(view, "link-panel", "[role=alert]", "搜索词无效")
  end

  test "epics only: the project's epics without a query, others by search", %{view: view} do
    view |> element("#task-epic-edit") |> render_click()
    assert results(view, "epic-panel") == ["WEB-1"]

    render_change(picker(view, "epic-panel"), "search", %{"q" => "登录"})
    assert results(view, "epic-panel") == ["BOS-2"]

    render_change(picker(view, "epic-panel"), "search", %{"q" => "支付"})
    assert results(view, "epic-panel") == []
  end

  # Code review 1 P2: Enter submits the newest text; the debounced search may not have run.
  describe "Enter with a newer text than the last search" do
    defp picked(view), do: :sys.get_state(view.pid).socket.assigns.collab.link_panel.picked

    test "changed text: picks from the submitted query", %{view: view} do
      view |> element("#task-links-add") |> render_click()
      render_change(picker(view, "link-panel"), "search", %{"q" => "BOS-1"})
      render_submit(picker(view, "link-panel"), "pick_first", %{"q" => "BOS-2"})
      assert picked(view).id == "BOS-2"
    end

    test "first text, no search yet", %{view: view} do
      view |> element("#task-links-add") |> render_click()
      render_submit(picker(view, "link-panel"), "pick_first", %{"q" => "支付"})
      assert picked(view).id == "BOS-1"
    end

    test "no match, invalid or empty text: nothing picked, the old results gone", %{view: view} do
      view |> element("#task-links-add") |> render_click()
      render_change(picker(view, "link-panel"), "search", %{"q" => "BOS-1"})

      render_submit(picker(view, "link-panel"), "pick_first", %{"q" => "不存在的词"})
      assert picked(view) == nil
      assert results(view, "link-panel") == []

      render_submit(picker(view, "link-panel"), "pick_first", %{"q" => String.duplicate("长", 250)})

      assert picked(view) == nil
      assert in_portal?(view, "link-panel", "[role=alert]", "搜索词无效")

      render_change(picker(view, "link-panel"), "search", %{"q" => "BOS-1"})
      render_submit(picker(view, "link-panel"), "pick_first", %{"q" => ""})
      assert picked(view) == nil
    end
  end
end
