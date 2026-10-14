defmodule HelmsmanWeb.RootLayoutTest do
  use HelmsmanWeb.ConnCase, async: true

  @theme_js Path.expand("../../assets/js/theme.js", __DIR__)

  test "the theme script runs before the stylesheet and the overlay root exists", %{conn: conn} do
    html = conn |> get("/dev/ui") |> html_response(200)
    [head, body] = String.split(html, "</head>", parts: 2)

    # A blocking external script (the CSP allows no inline script).
    [theme_tag] = Regex.run(~r/<script[^>]*theme\.js[^>]*>/, head)
    refute theme_tag =~ ~r/\b(defer|async|type="module")\b/
    {script_at, _} = :binary.match(head, theme_tag)
    {link_at, _} = :binary.match(head, ~s(rel="stylesheet"))
    assert script_at < link_at
    refute head =~ ~r/<script(?![^>]*\bsrc=)[^>]*>/

    theme = File.read!(@theme_js)
    assert theme =~ "phx:theme"
    assert theme =~ "data-sidebar"
    assert theme =~ "data-platform"
    assert theme =~ "prefers-color-scheme: dark"
    assert theme =~ "helmsman-dark"
    assert body =~ ~s(<div id="hm-overlays"></div>)
    assert html =~ ~r/<html[^>]* lang="zh-CN">/
  end
end
