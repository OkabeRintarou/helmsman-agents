defmodule HelmsmanWeb.Components.FilterBarTest do
  use HelmsmanWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  test "restores chips from the URL", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/dev/ui?status=new,in_progress&label=api")

    assert has_element?(view, "#demo-filters-chip-status", "状态：")
    assert has_element?(view, "#demo-filters-chip-status", "新建、进行中")
    assert has_element?(view, "#demo-filters-chip-label", "api")
    assert has_element?(view, ~s(#demo-filters-menu-popover [aria-checked="true"]), "新建")
  end

  test "removing one chip keeps the other filters", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/dev/ui?status=new,in_progress&label=api")

    view |> element("#demo-filters-chip-label a") |> render_click()

    assert_patch(view, "/dev/ui?status=new%2Cin_progress")
    refute has_element?(view, "#demo-filters-chip-label")
    assert has_element?(view, "#demo-filters-chip-status")
  end

  test "the search box is debounced and patches the URL", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/dev/ui?label=api")
    assert has_element?(view, ~s(#demo-filters-search input[phx-debounce="300"]))

    view |> form("#demo-filters-search", %{q: "panel"}) |> render_change()
    assert_patch(view, "/dev/ui?label=api&q=panel")
  end
end
