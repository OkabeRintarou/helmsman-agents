defmodule HelmsmanWeb.Components.MenuTest do
  use HelmsmanWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Phoenix.Component
  import HelmsmanWeb.Components.Menu

  alias Phoenix.LiveView.JS

  defp render_menu(items) do
    assigns = %{items: items}

    rendered_to_string(~H"""
    <.dropdown id="m" items={@items} label="操作">
      <:trigger>Open</:trigger>
    </.dropdown>
    """)
  end

  test "trigger and popover carry menu semantics and close commands" do
    html = render_menu([%{label: "重命名", on_select: "rename"}])

    assert html =~ ~s(id="m-trigger")
    assert html =~ ~s(aria-haspopup="menu")
    assert html =~ ~s(aria-expanded="false")
    assert html =~ ~s(aria-controls="m-popover")
    assert html =~ "data-hm-menu"
    assert html =~ "data-cancel="
    assert html =~ ~s(role="menu")
    assert html =~ ~s(role="menuitem")
    refute html =~ "m-filter"
  end

  test "item kinds: icon, description, shortcut, checked, group, divider, disabled, danger" do
    html =
      render_menu([
        %{
          label: "重命名",
          icon: "lucide-pencil",
          shortcut: "R",
          description: "改名",
          on_select: JS.push("r")
        },
        %{type: :divider},
        %{label: "高", group: "优先级", checked: true, on_select: "p"},
        %{label: "低", group: "优先级", checked: false, on_select: "p"},
        %{label: "移动", disabled_reason: "只有管理员可以移动"},
        %{label: "删除", danger: true, on_select: "delete", value: %{id: 1}},
        %{label: "打开", navigate: "/w/acme"}
      ])

    assert html =~ "lucide-pencil"
    assert html =~ "改名"
    assert html =~ ~r/<kbd[^>]*>\s*R\s*<\/kbd>/
    assert html =~ ~s(role="separator")
    assert length(Regex.scan(~r/>\s*优先级\s*</, html)) == 1
    assert html =~ ~s(role="menuitemradio" aria-checked="true")
    assert html =~ ~s(role="menuitemradio" aria-checked="false")
    assert html =~ ~s(aria-disabled="true")
    assert html =~ "只有管理员可以移动"
    assert html =~ "text-danger-fg"
    assert html =~ ~s(&quot;event&quot;:&quot;delete&quot;)
    assert html =~ ~s(href="/w/acme")
  end

  test "disabled items have no action" do
    html = render_menu([%{label: "移动", disabled_reason: "不行", on_select: "move"}])
    refute html =~ "&quot;move&quot;"
  end

  test "a filter box appears only above 8 items" do
    eight = for i <- 1..8, do: %{label: "item #{i}"}
    refute filterable?(eight)
    assert filterable?(eight ++ [%{type: :divider}]) == false
    assert filterable?(eight ++ [%{label: "item 9"}])
    assert filter_threshold() == 8
  end

  test "filter_items/2 matches labels case-insensitively and drops dividers" do
    items = [%{label: "Alice"}, %{type: :divider}, %{label: "bob"}]
    assert filter_items(items, "") == items
    assert filter_items(items, "  ALI ") == [%{label: "Alice"}]
  end

  test "long menus filter on the server", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/dev/ui")

    assert has_element?(view, "#demo-long-menu-filter")
    refute has_element?(view, "#demo-menu-filter")
    assert has_element?(view, "#demo-long-menu-menu", "mallory")

    view |> form("#demo-long-menu-popover form", %{query: "ma"}) |> render_change()

    assert has_element?(view, "#demo-long-menu-menu", "mallory")
    refute has_element?(view, "#demo-long-menu-menu", "alice")

    view |> form("#demo-long-menu-popover form", %{query: "zzz"}) |> render_change()
    assert has_element?(view, "#demo-long-menu-menu", "没有匹配的选项")
  end

  test "first_selectable/2 skips disabled items and dividers" do
    items = [%{type: :divider}, %{label: "bob", disabled_reason: "no"}, %{label: "bobby"}]
    assert first_selectable(items, "bob") == %{label: "bobby"}
    assert first_selectable(items, "zzz") == nil
  end

  test "item ids are stable across filtering", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/dev/ui")
    assert has_element?(view, "#demo-long-menu-item-10", "mallory")
    view |> form("#demo-long-menu-popover form", %{query: "mall"}) |> render_change()
    assert has_element?(view, "#demo-long-menu-item-10", "mallory")
  end

  test "Enter in the filter box resolves on the full list, not the rendered one", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/dev/ui")
    list = with_target(view, "#demo-long-menu-list")

    # The rendered list was filtered for an older query …
    view |> form("#demo-long-menu-popover form", %{query: "oscar"}) |> render_change()
    refute has_element?(view, "#demo-long-menu-menu", "bob")

    # … Enter with the new text still finds the match and renders it before replying.
    render_click(list, "select_first", %{"query" => "bob"})
    assert_reply(view, %{id: "demo-long-menu-item-1"})
    assert has_element?(view, "#demo-long-menu-item-1", "bob")

    render_click(list, "select_first", %{"query" => "zzz"})
    assert_reply(view, %{} = reply)
    assert reply == %{}
  end

  test "selecting an item pushes its event", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/dev/ui")
    view |> element("#demo-long-menu-menu button", "oscar") |> render_click()
    assert render(view) =~ "selected: oscar"
  end
end
