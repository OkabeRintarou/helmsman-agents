defmodule HelmsmanWeb.Dev.UiLiveTest do
  use HelmsmanWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  test "GET /dev/ui renders every section", %{conn: conn} do
    conn = get(conn, "/dev/ui")
    html = html_response(conn, 200)

    for section <-
          ~w(buttons forms overlays menus tabs status identity brands text markdown layout table icons tokens contrast) do
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

  test "the Markdown section shows highlighted code and a Mermaid block", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/dev/ui")

    for selector <- [
          "pre.lumis",
          "pre[data-mermaid]",
          "table",
          "blockquote",
          "input[type=checkbox]",
          "section li[id]",
          "span.hm-mention",
          "h2"
        ] do
      assert has_element?(view, "#section-markdown .hm-prose " <> selector), selector
    end

    assert has_element?(view, "#section-markdown #demo-editor[data-hm-editor]")
  end

  test "identity marks and brand icons in both themes (add-actor-avatars 2.4)", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/dev/ui")

    for theme <- ~w(helmsman-light helmsman-dark) do
      for kind <- ~w(human agent squad system) do
        assert has_element?(
                 view,
                 "#marks-#{theme}[data-theme=#{theme}] [data-actor-mark=#{kind}]"
               )
      end

      assert has_element?(view, "#marks-#{theme} img[data-avatar]")
      assert has_element?(view, "#marks-#{theme} [data-brand=githubcopilot]")
      assert has_element?(view, "#brands-#{theme} [data-brand=deepseek] img")
      assert has_element?(view, "#brands-#{theme} [data-brand=openai] svg")
      assert has_element?(view, "#brands-#{theme} [data-brand=none] .lucide-cpu")
      assert has_element?(view, "#brands-#{theme} [data-model-vendor=zai]")
    end

    assert has_element?(view, "#demo-avatar-menu-trigger[aria-label='更换头像']")
  end
end
