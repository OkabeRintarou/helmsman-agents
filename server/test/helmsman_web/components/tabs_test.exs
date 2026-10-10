defmodule HelmsmanWeb.Components.TabsTest do
  use HelmsmanWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Phoenix.Component
  import HelmsmanWeb.Components.Layout

  test "the active tab is marked and counts are shown" do
    assigns = %{}

    html =
      rendered_to_string(~H"""
      <.tabs label="视图">
        <:tab patch="?tab=a" active count={12}>A</:tab>
        <:tab patch="?tab=b">B</:tab>
      </.tabs>
      """)

    assert html =~ ~r/<nav[^>]* aria-label="视图"/
    assert html =~ ~r/href="\?tab=a"[^>]*aria-current="page"/
    refute html =~ ~r/href="\?tab=b"[^>]*aria-current/
    assert html =~ ~r/>\s*12\s*</
    assert html =~ ~s(data-phx-link="patch")
  end

  test "deep links select the tab and switching patches the URL", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/dev/ui?tab=tokens")
    assert has_element?(view, ~s(#section-tabs a[aria-current="page"]), "Token")

    view |> element("#section-tabs a", "组件") |> render_click()
    assert_patch(view, "/dev/ui?tab=components")
    assert has_element?(view, "#tab-content", "tab: components")
  end
end
