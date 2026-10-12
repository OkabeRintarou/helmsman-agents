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

  describe "single-select dimensions and the search option" do
    import Phoenix.Component, only: [sigil_H: 2]

    defp bar(filters, search) do
      assigns = %{filters: filters, search: search}

      rendered_to_string(~H"""
      <HelmsmanWeb.Components.FilterBar.filter_bar
        id="f"
        path="/w/acme/p/BOS"
        filters={@filters}
        search={@search}
        dimensions={[
          %{key: :status, label: "状态", options: [{"new", "新建"}, {"done", "待验收"}]},
          %{key: :label, label: "标签", single: true, options: [{"api", "api"}, {"ui", "ui"}]}
        ]}
      />
      """)
    end

    test "choosing another option replaces the value; choosing it again clears it" do
      html = bar(%{label: "api", status: ["new"]}, true)

      assert html =~ ~s(id="filter-label-ui")
      assert [ui] = Regex.run(~r/<a[^>]*id="filter-label-ui"[^>]*>/, html)
      assert ui =~ ~s(href="/w/acme/p/BOS?label=ui&amp;status=new")
      refute ui =~ "api"

      [api] = Regex.run(~r/<a[^>]*id="filter-label-api"[^>]*>/, html)
      assert api =~ ~s(href="/w/acme/p/BOS?status=new")

      [done] = Regex.run(~r/<a[^>]*id="filter-status-done"[^>]*>/, html)
      assert done =~ "status=new%2Cdone"
    end

    test "search={false} renders no search box" do
      assert bar(%{}, true) =~ "data-hm-filter-input"
      refute bar(%{}, false) =~ "data-hm-filter-input"
    end
  end
end
