defmodule HelmsmanWeb.Components.TooltipTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest
  import Phoenix.Component
  import HelmsmanWeb.CoreComponents

  test "renders the tooltip next to its trigger" do
    assigns = %{}

    html =
      rendered_to_string(~H"""
      <.tooltip id="sync-tip" text="同步中"><button aria-describedby="sync-tip">S</button></.tooltip>
      """)

    assert html =~ "hm-tooltip-host"
    assert html =~ ~s(<span id="sync-tip" role="tooltip")
    assert html =~ "hm-tooltip "
    assert html =~ "同步中"
  end

  test "without an id the tooltip is hidden from assistive technology" do
    assigns = %{}

    html =
      rendered_to_string(~H"""
      <.tooltip text="同步中"><span>S</span></.tooltip>
      """)

    assert html =~ ~s(aria-hidden="true")
    refute html =~ ~s(role="tooltip")
  end

  test "the CSS shows tooltips after 300ms on hover and immediately on keyboard focus" do
    css = File.read!(Path.expand("../../../assets/css/app.css", __DIR__))
    assert css =~ ~r/\.hm-tooltip-host:hover > \.hm-tooltip \{[^}]*transition-delay: 300ms/
    assert css =~ ~r/:focus-visible > \.hm-tooltip \{[^}]*transition-delay: 0s/
  end
end
