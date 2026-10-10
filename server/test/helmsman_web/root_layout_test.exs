defmodule HelmsmanWeb.RootLayoutTest do
  use HelmsmanWeb.ConnCase, async: true

  test "the theme script runs before the stylesheet and the overlay root exists", %{conn: conn} do
    html = conn |> get("/dev/ui") |> html_response(200)
    [head, body] = String.split(html, "</head>", parts: 2)

    {script_at, _} = :binary.match(head, "phx:theme")
    {link_at, _} = :binary.match(head, ~s(rel="stylesheet"))
    assert script_at < link_at

    assert head =~ "data-sidebar"
    assert head =~ "data-platform"
    assert head =~ "prefers-color-scheme: dark"
    assert head =~ "helmsman-dark"
    assert body =~ ~s(<div id="hm-overlays"></div>)
    assert html =~ ~r/<html[^>]* lang="zh-CN">/
  end
end
