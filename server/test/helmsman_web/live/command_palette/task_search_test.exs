defmodule HelmsmanWeb.CommandPalette.TaskSearchTest do
  @moduledoc """
  Spec web-app-shell 命令面板 (add-search-query-ui D1): full-text task hits in the
  palette, snippets that may be nil, the query-page entry.
  """
  use HelmsmanWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Helmsman.AccountsFixtures
  import Helmsman.ProjectsFixtures
  import Helmsman.WorkspacesFixtures

  alias Helmsman.Feedback
  alias HelmsmanWeb.CommandPalette.TaskSearch

  setup %{conn: conn} do
    user = user_fixture(%{display_name: "alice"})
    ws = workspace_fixture(user, %{name: "Acme"})
    scope = workspace_scope_fixture(user, ws)
    project_fixture(scope, %{key: "BOS", name: "Bosun"})

    %{conn: log_in_user(conn, user), ws: ws, scope: scope}
  end

  defp open(ctx), do: live(ctx.conn, "/w/#{ctx.ws.slug}/projects")
  defp palette(view), do: view |> element("#command-palette-dialog-portal") |> render()

  defp search(view, q),
    do: view |> with_target("#command-palette") |> render_click("search", %{"q" => q})

  defp execute(view, index),
    do:
      view
      |> with_target("#command-palette")
      |> render_click("execute", %{"index" => to_string(index)})

  # The index of the first option whose text contains `text`.
  defp index_of(view, text) do
    view
    |> palette()
    |> String.split(~s(id="command-palette-dialog-result-))
    |> Enum.drop(1)
    |> Enum.find_value(fn chunk ->
      [index, rest] = String.split(chunk, ~s("), parts: 2)
      if rest =~ text, do: index
    end)
  end

  test "全文检索任务：片段高亮", ctx do
    t1 = task_fixture(ctx.scope, "BOS", %{title: "登录页改版"})
    t2 = task_fixture(ctx.scope, "BOS", %{title: "重试", description: "处理登录失败重试的边界情况"})

    {:ok, view, _html} = open(ctx)
    search(view, "登录")
    html = palette(view)

    assert html =~ "#{t1.ident} 登录页改版"
    assert html =~ "<mark>登录</mark>"

    execute(view, index_of(view, t2.ident))
    assert_redirect(view, "/w/#{ctx.ws.slug}/t/#{t2.ident}")
  end

  test "Feedback 命中：作者与锚点", ctx do
    task = task_fixture(ctx.scope, "BOS", %{title: "上线"})
    {:ok, _} = Feedback.add(ctx.scope, task.ident, %{content: "第一条"})
    {:ok, _} = Feedback.add(ctx.scope, task.ident, %{content: "第二条"})
    {:ok, entry} = Feedback.add(ctx.scope, task.ident, %{content: "需要准备回滚方案"})

    {:ok, view, _html} = open(ctx)
    search(view, "回滚方案")
    html = palette(view)

    assert html =~ ~r/：[^<]*<mark>/

    execute(view, index_of(view, task.ident))
    assert_redirect(view, "/w/#{ctx.ws.slug}/t/#{task.ident}#feedback-#{entry.seq}")
  end

  test "按编号输入不检索", ctx do
    task_fixture(ctx.scope, "BOS", %{title: "bos-12 相关"})
    {:ok, view, _html} = open(ctx)
    search(view, "bos-12")
    html = palette(view)

    assert html =~ "跳转到任务"
    refute html =~ "在查询页搜索"
    refute html =~ "bos-12 相关"
  end

  test "在查询页搜索：引号与反斜杠被转义", ctx do
    {:ok, view, _html} = open(ctx)
    search(view, ~s(say "hi"))
    execute(view, index_of(view, "在查询页搜索"))

    assert_redirect(
      view,
      "/w/#{ctx.ws.slug}/query?" <> URI.encode_query(%{"bql" => ~S|text ~ "say \"hi\""|})
    )

    assert TaskSearch.quote_bql(~S|a\b"c|) == ~S|a\\b\"c|
  end

  test "片段不执行 HTML", ctx do
    task_fixture(ctx.scope, "BOS", %{
      title: "发布",
      description: "<img src=x onerror=alert(1)> 部署说明"
    })

    {:ok, view, _html} = open(ctx)
    search(view, "部署")
    html = palette(view)

    assert html =~ "&lt;img"
    refute html =~ "<img"
  end

  test "没有片段的命中：标题、标签", ctx do
    t1 = task_fixture(ctx.scope, "BOS", %{title: "发布清单", description: ""})
    t2 = task_fixture(ctx.scope, "BOS", %{title: "整理", labels: ["release"]})

    {:ok, view, _html} = open(ctx)
    search(view, "发布清单")
    assert palette(view) =~ "#{t1.ident} 发布清单"
    refute palette(view) =~ "data-snippet"
    execute(view, index_of(view, t1.ident))
    assert_redirect(view, "/w/#{ctx.ws.slug}/t/#{t1.ident}")

    {:ok, view, _html} = open(ctx)
    search(view, "release")
    assert palette(view) =~ "#{t2.ident} 整理"
  end

  test "Feedback 片段为空时显示作者与编号；作者名转义" do
    hit = %{
      task: %{id: "BOS-7", title: "x", status: "new"},
      snippet: nil,
      feedback: %{id: "BOS-7#3", author: %{name: "<b>bot</b>", kind: "agent"}, snippet: nil}
    }

    assert TaskSearch.sublabel(hit) == %{sublabel: "<b>bot</b> 的 Feedback #3"}

    with_snippet = put_in(hit, [:feedback, :snippet], [%{text: "回滚", hit: true}])
    %{sublabel_html: html} = TaskSearch.sublabel(with_snippet)
    assert Phoenix.HTML.safe_to_string(html) == "&lt;b&gt;bot&lt;/b&gt;：<mark>回滚</mark>"
  end

  test "过长的输入只给出「在查询页搜索」", ctx do
    {:ok, view, _html} = open(ctx)
    search(view, String.duplicate("长", 201))
    html = palette(view)

    assert html =~ "在查询页搜索"
    refute html =~ "没有匹配的结果"
  end
end
