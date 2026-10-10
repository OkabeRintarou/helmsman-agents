defmodule HelmsmanWeb.Components.DataTableTest do
  use HelmsmanWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  defp row_ids(html) do
    ~r/<tr id="(row-\d+)"/ |> Regex.scan(html, capture: :all_but_first) |> List.flatten()
  end

  test "load more appends rows and keeps existing DOM ids", %{conn: conn} do
    {:ok, view, html} = live(conn, "/dev/ui")
    first = row_ids(html)
    assert first == Enum.map(1..5, &"row-#{&1}")

    html = view |> element("#demo-rows-more") |> render_click()
    assert row_ids(html) == Enum.map(1..10, &"row-#{&1}")

    view |> element("#demo-rows-more") |> render_click()
    refute has_element?(view, "#demo-rows-more")
  end

  test "stream_insert updates only that row and marks it for a flash", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/dev/ui")
    before = view |> element("#row-2") |> render()

    view |> element("#bump-row") |> render_click()

    assert has_element?(view, "#row-1", "更新后的标题 1")
    assert has_element?(view, "#row-1-v#{:erlang.phash2(1)}")
    assert view |> element("#row-2") |> render() == before
    assert view |> element("#row-1 span[id^=row-1-v]") |> render() =~ "animate-row-flash"
  end

  test "secondary columns hide on narrow screens and rows are 36px", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/dev/ui")
    assert has_element?(view, "#demo-rows tr.h-9")
    assert has_element?(view, "#row-1 td.hidden.md\\:table-cell")
  end
end
