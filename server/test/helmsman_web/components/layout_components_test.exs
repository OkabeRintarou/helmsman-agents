defmodule HelmsmanWeb.Components.LayoutComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest
  import Phoenix.Component
  import HelmsmanWeb.Components.Layout
  import HelmsmanWeb.CoreComponents, only: [button: 1]

  test "page header: title, breadcrumbs, actions and the drawer button" do
    assigns = %{}

    html =
      rendered_to_string(~H"""
      <.page_header title="BOS-12">
        <:crumb navigate="/w/acme/projects/bos">BOS</:crumb>
        <:actions><.button variant="primary">开始</.button></:actions>
      </.page_header>
      """)

    assert html =~ "h-12"
    assert html =~ ~r/<h1[^>]*>\s*BOS-12\s*<\/h1>/
    assert html =~ ~s(aria-label="面包屑")
    assert html =~ ~s(href="/w/acme/projects/bos")
    assert html =~ "开始"
    assert html =~ ~s(id="hm-drawer-toggle")
    assert html =~ "lg:hidden"
  end

  test "property rows show a placeholder for empty values" do
    assigns = %{}

    html =
      rendered_to_string(~H"""
      <.property_list>
        <.property_row label="截止日期" value={nil} />
        <.property_row label="里程碑" value="" placeholder="未设置" />
        <.property_row label="标签" value="api" editable />
        <.property_row label="负责人"><span>alice</span></.property_row>
      </.property_list>
      """)

    assert html =~ ~r/<span class="text-fg-subtle">\s*—\s*<\/span>/
    assert html =~ "未设置"
    assert html =~ "api"
    assert html =~ "lucide-pencil"
    assert html =~ "alice"
    assert html =~ "min-h-8"
  end

  test "empty state with a create action" do
    assigns = %{}

    html =
      rendered_to_string(~H"""
      <.empty_state title="还没有任务" description="创建第一个">
        <:action><.button>新建任务</.button></:action>
      </.empty_state>
      """)

    assert html =~ "还没有任务"
    assert html =~ "新建任务"
    refute html =~ "清除筛选"
  end

  test "filtered empty state offers to clear filters" do
    assigns = %{}

    html =
      rendered_to_string(~H"""
      <.empty_state kind={:filtered} on_clear={Phoenix.LiveView.JS.patch("/w/acme/tasks")} />
      """)

    assert html =~ "没有符合条件的结果"
    assert html =~ "清除筛选"
    assert html =~ "/w/acme/tasks"
  end
end
