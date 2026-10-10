defmodule HelmsmanWeb.Components.FlashTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest
  import HelmsmanWeb.CoreComponents, only: [flash: 1]

  test "info is a status live region that fades out after 5 seconds" do
    html = render_component(&flash/1, kind: :info, flash: %{"info" => "已保存"})
    assert html =~ ~s(role="status")
    assert html =~ "animate-flash-out"
    assert html =~ "已保存"
    refute html =~ "aria-label=\"关闭\""
  end

  test "error is an alert with a close button" do
    html = render_component(&flash/1, kind: :error, flash: %{"error" => "失败"})
    assert html =~ ~s(role="alert")
    assert html =~ ~s(aria-label="关闭")
    assert html =~ "lv:clear-flash"
    refute html =~ "animate-flash-out"
  end

  test "the fade keeps its 5s delay under reduced motion" do
    css = File.read!(Path.expand("../../../assets/css/app.css", __DIR__))
    assert css =~ "--animate-flash-out: hm-flash-out 200ms ease-out 5s forwards;"
    [reduced] = Regex.run(~r/@media \(prefers-reduced-motion: reduce\) \{.*?\n\}/s, css)
    assert reduced =~ "animation-duration: 0.01ms !important"
    assert reduced =~ "transition-duration: 0.01ms !important"
    assert reduced =~ "animation-iteration-count: 1 !important"
    refute reduced =~ "animation-delay"
    refute reduced =~ "animation: none"
  end
end
