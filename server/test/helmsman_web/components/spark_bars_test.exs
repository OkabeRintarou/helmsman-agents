defmodule HelmsmanWeb.Components.SparkBarsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest
  import HelmsmanWeb.Components.Text

  test "bars carry a 日期：数值 title" do
    points = [{~D[2026-10-01], 2}, {~D[2026-10-02], 0}, {~D[2026-10-03], 5}]
    html = render_component(&spark_bars/1, points: points, label: "运行次数")

    assert html =~ ~s(role="img")
    assert html =~ ~s(aria-label="运行次数")
    assert length(Regex.scan(~r/<rect/, html)) == 2
    assert html =~ "<title>2026-10-01：2</title>"
    assert html =~ "<title>2026-10-03：5</title>"
    assert html =~ "<line"
  end

  test "all-zero data draws only the baseline" do
    points = for d <- 1..30, do: {Date.add(~D[2026-09-01], d), 0}
    html = render_component(&spark_bars/1, points: points, label: "x")

    assert html =~ "<line"
    refute html =~ "<rect"
  end
end
