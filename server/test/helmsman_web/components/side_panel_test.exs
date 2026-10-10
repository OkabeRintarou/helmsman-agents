defmodule HelmsmanWeb.Components.SidePanelTest do
  use HelmsmanWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  # Overlays are teleported through <template> portals, which LiveViewTest cannot query
  # into; we render the portal and push the events the panel's form would send.
  defp panel_html(view), do: view |> element("#demo-panel-portal") |> render()

  test "?panel=new opens the panel on load", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/dev/ui?panel=new")
    html = panel_html(view)

    assert html =~ ~s(id="demo-panel")
    assert html =~ ~r/phx-mounted="[^"]*inert/
    assert html =~ "sm:w-[480px]"
    assert html =~ ~s(id="demo-panel-title")
  end

  test "without the parameter the panel is not rendered", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/dev/ui")
    refute panel_html(view) =~ ~s(id="demo-panel")
  end

  test "closing patches the parameter away", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/dev/ui?panel=new")
    html = panel_html(view)

    assert html =~
             ~r/data-cancel="\[\[&quot;patch&quot;,\{[^}]*&quot;href&quot;:&quot;\/dev\/ui&quot;/

    render_patch(view, "/dev/ui")
    refute panel_html(view) =~ ~s(id="demo-panel")
  end

  test "a failed submit keeps the panel open with the input and shows the error", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/dev/ui?panel=new")

    render_change(view, "validate_panel", %{task: %{title: "", note: "保留的说明"}})
    assert panel_html(view) =~ ~r/id="demo-panel-backdrop"(?![^>]*phx-click)[^>]*>/

    render_submit(view, "save_panel", %{task: %{title: "", note: "保留的说明"}})
    html = panel_html(view)

    assert html =~ ~s(id="demo-panel")
    assert html =~ ~s(role="alert")
    assert html =~ "保存失败"
    assert html =~ "保留的说明"
    assert html =~ ~s(aria-invalid="true")
  end

  test "a successful submit closes the panel through the URL", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/dev/ui?panel=new")
    render_submit(view, "save_panel", %{task: %{title: "新任务", note: ""}})

    assert_patch(view, "/dev/ui")
    refute panel_html(view) =~ ~s(id="demo-panel")
    assert render(view) =~ "已保存"
  end
end
