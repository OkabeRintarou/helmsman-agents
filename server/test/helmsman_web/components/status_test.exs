defmodule HelmsmanWeb.Components.StatusTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest
  import HelmsmanWeb.Components.Status

  @tasks [
    {"NEW", "新建", "lucide-circle-dashed", "text-fg-muted", "text-fg-muted"},
    {"IN_PROGRESS", "进行中", "lucide-circle-dot", "text-warning", "text-warning-fg"},
    {"DONE", "待验收", "lucide-circle-check", "text-info", "text-info-fg"},
    {"VERIFIED", "已验收", "lucide-check", "text-success", "text-success-fg"},
    {"REJECTED", "已拒绝", "lucide-circle-x", "text-danger", "text-danger-fg"},
    {"CANCELLED", "已撤销", "lucide-circle-slash", "text-fg-subtle", "text-fg-subtle"}
  ]

  @runs [
    {"deferred", "等待中", "lucide-clock", "text-fg-muted"},
    {"queued", "排队中", "lucide-ellipsis", "text-fg-muted"},
    {"claimed", "准备中", "lucide-loader-circle", "text-info"},
    {"running", "运行中", "lucide-loader-circle", "text-brand"},
    {"cancelling", "停止中", "lucide-square", "text-warning"},
    {"succeeded", "已结束", "lucide-check", "text-success"},
    {"failed", "失败", "lucide-x", "text-danger"},
    {"cancelled", "已停止", "lucide-slash", "text-fg-subtle"}
  ]

  for {status, label, icon, graphic, text} <- @tasks do
    test "task status #{status}" do
      html = render_component(&status_badge/1, status: unquote(status))
      assert html =~ unquote(label)
      assert html =~ unquote(icon)
      assert html =~ unquote(graphic)
      assert html =~ unquote(text)

      icon_html = render_component(&status_icon/1, status: String.downcase(unquote(status)))
      assert icon_html =~ ~s(role="img")
      assert icon_html =~ ~s(aria-label="状态：#{unquote(label)}")
      assert icon_html =~ "hm-tooltip"
    end
  end

  test "status badges use the tinted background of their tone" do
    assert render_component(&status_badge/1, status: :in_progress) =~ "tint-warning"
    assert render_component(&status_badge/1, status: :done) =~ "tint-info"
  end

  for {status, label, icon, graphic} <- @runs do
    test "run status #{status}" do
      html = render_component(&run_status_badge/1, status: unquote(status))
      assert html =~ unquote(label)
      assert html =~ unquote(icon)
      assert html =~ unquote(graphic)
    end
  end

  test "running spins and pulses only when motion is allowed" do
    html = render_component(&run_status_badge/1, status: :running)
    assert html =~ "motion-safe:animate-spin"
    assert html =~ "motion-safe:animate-pulse-soft"
    refute render_component(&run_status_badge/1, status: :succeeded) =~ "animate-"
  end

  test "succeeded runs read 已结束, not 完成" do
    refute render_component(&run_status_badge/1, status: "succeeded") =~ "完成"
  end

  test "unknown values fall back to a neutral 未知 badge" do
    for fun <- [&status_badge/1, &run_status_badge/1], value <- ["bogus", nil, 42] do
      html = render_component(fun, status: value)
      assert html =~ "未知"
      assert html =~ "text-fg-muted"
    end
  end

  for {priority, bars, label} <- [{"low", 1, "低"}, {"medium", 2, "中"}, {"high", 3, "高"}] do
    test "priority #{priority}" do
      html = render_component(&priority_icon/1, priority: unquote(priority))
      assert html =~ ~s(aria-label="优先级：#{unquote(label)}")
      assert html =~ ~s(data-priority="#{unquote(bars)}")
      assert length(Regex.scan(~r/fill-current/, html)) == unquote(bars)
      assert html =~ if(unquote(bars) == 3, do: "text-warning", else: "text-fg-muted")
    end
  end
end
