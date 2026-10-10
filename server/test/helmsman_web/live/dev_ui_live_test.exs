defmodule HelmsmanWeb.Dev.UiLiveTest do
  use HelmsmanWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  test "GET /dev/ui renders every section", %{conn: conn} do
    conn = get(conn, "/dev/ui")
    html = html_response(conn, 200)

    for section <-
          ~w(buttons forms overlays menus tabs status identity text layout table icons tokens contrast) do
      assert html =~ ~s(id="section-#{section}"), "missing section #{section}"
    end
  end

  test "lists all 14 status badges, theme switch and the contrast table", %{conn: conn} do
    {:ok, view, html} = live(conn, "/dev/ui")

    assert length(
             Regex.scan(
               ~r/data-status="(new|in_progress|done|verified|rejected|cancelled)"/,
               html
             )
           ) >= 6

    assert length(Regex.scan(~r/data-run-status="/, html)) == 8
    assert has_element?(view, ~s([data-theme-option="dark"]))
    assert has_element?(view, "#contrast-helmsman-light")
    assert has_element?(view, "#contrast-helmsman-dark")
  end
end
