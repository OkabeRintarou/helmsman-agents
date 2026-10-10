defmodule HelmsmanWeb.Components.TextTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest
  import Phoenix.Component
  import HelmsmanWeb.Components.Text
  import HelmsmanWeb.CoreComponents, only: [kbd: 1]

  test "task id link" do
    html = render_component(&task_id_link/1, ident: "BOS-12", workspace: "acme", title: "命令面板")
    assert html =~ ~s(href="/w/acme/t/BOS-12")
    assert html =~ "font-mono"
    assert html =~ "命令面板"
    refute html =~ "line-through"

    assert render_component(&task_id_link/1,
             ident: "BOS-7",
             workspace: "acme",
             status: "CANCELLED"
           ) =~
             "line-through"
  end

  @now ~U[2026-10-10 06:00:00Z]

  for {seconds, text} <- [
        {10, "刚刚"},
        {3 * 60, "3 分钟前"},
        {5 * 3600, "5 小时前"},
        {30 * 3600, "昨天"},
        {3 * 86_400, "3 天前"},
        {8 * 86_400, "2026-10-02"}
      ] do
    test "relative time #{text}" do
      at = DateTime.add(@now, -unquote(seconds))
      html = render_component(&relative_time/1, id: "t", at: at, now: @now)
      assert html =~ unquote(text)
      assert html =~ ~s(datetime="#{DateTime.to_iso8601(at)}")
      assert html =~ ~s(phx-hook="HelmsmanWeb.Components.Text.LocalTime")
    end
  end

  test "relative time carries the translated templates for the hook" do
    html = render_component(&relative_time/1, id: "t", at: @now, now: @now)
    assert html =~ ~s(data-minutes="{n} 分钟前")
    assert html =~ ~s(data-yesterday="昨天")
  end

  test "kbd renders both modifiers for CSS to pick" do
    assigns = %{}

    html =
      rendered_to_string(~H"""
      <.kbd mod>K</.kbd>
      """)

    assert html =~ ~s(<span class="hm-kbd-mac">⌘</span>)
    assert html =~ ~s(<span class="hm-kbd-other">Ctrl+</span>)
    assert html =~ "K"

    css = File.read!(Path.expand("../../../assets/css/app.css", __DIR__))
    assert css =~ "html[data-platform=mac] .hm-kbd-mac"
  end
end
