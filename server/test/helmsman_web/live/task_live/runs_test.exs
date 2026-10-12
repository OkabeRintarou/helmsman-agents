defmodule HelmsmanWeb.TaskLive.RunsTest do
  @moduledoc "Spec web-runs 任务详情页的运行区、运行卡片、运行的实时刷新 (design D8)."
  use HelmsmanWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Helmsman.RunsFixtures

  alias Helmsman.{Actors, Agents, Dispatch, Tasks}
  alias HelmsmanWeb.TaskLive.Show

  setup %{conn: conn} do
    ctx = dispatch_fixture(%{access: "workspace"})
    {carol, carol_scope} = member_scope_fixture(ctx.workspace)
    {:ok, task} = Tasks.create(ctx.alice_scope, ctx.project.key, %{title: "修复登录"})

    Map.merge(ctx, %{
      conn: conn,
      carol: carol,
      carol_scope: carol_scope,
      task: task,
      alice_name: Actors.get_human(ctx.workspace.id, ctx.alice.id).name,
      carol_name: Actors.get_human(ctx.workspace.id, carol.id).name,
      path: "/w/#{ctx.workspace.slug}/t/#{task.ident}"
    })
  end

  defp open(ctx, user \\ nil), do: live(log_in_user(ctx.conn, user || ctx.alice), ctx.path)

  defp eventually(fun, tries \\ 40) do
    cond do
      fun.() -> true
      tries == 0 -> flunk("condition never held")
      true -> Process.sleep(50) && eventually(fun, tries - 1)
    end
  end

  defp assign!(ctx, start \\ true) do
    {:ok, task} = Tasks.get(ctx.alice_scope, ctx.task.ident)

    {:ok, _} =
      Tasks.update(
        ctx.alice_scope,
        ctx.task.ident,
        %{assignee: "keel/dev", start: start},
        task.lock_version
      )
  end

  test "没有运行", ctx do
    {:ok, view, _html} = open(ctx)
    assert has_element?(view, "#task-runs-empty", "还没有运行")
    refute has_element?(view, "#task-runs-empty", "指派后会自动开始运行")

    assign!(ctx, false)
    {:ok, view, _html} = open(ctx)
    assert has_element?(view, "#task-runs-empty", "指派后会自动开始运行")
  end

  test "a queued run's card", ctx do
    assign!(ctx)
    [run] = runs_of(ctx.task.id)
    {:ok, view, _html} = open(ctx)

    card = "#run-card-#{run.id}"
    assert has_element?(view, ~s(#{card} [data-run-status="queued"]), "排队中")

    assert has_element?(
             view,
             ~s(#{card} a[data-run-agent][href="/w/#{ctx.workspace.slug}/agents/keel/dev"])
           )

    assert has_element?(view, "#{card} [data-run-triggers]", "#{ctx.alice_name} 指派")
    assert has_element?(view, "#{card} [data-run-time]", "排队于")
    assert has_element?(view, ~s(#{card} a[href="#{ctx.path}?run=#{run.id}"]), "执行记录")
    refute has_element?(view, "#task-runs-empty")
  end

  test "merged triggers: 等 2 条触发 with every trigger in the tooltip", ctx do
    assign!(ctx)
    {:ok, _} = Dispatch.run_agent(ctx.carol_scope, "keel/dev", ctx.task.ident, "先补测试")
    [run] = runs_of(ctx.task.id)
    {:ok, view, _html} = open(ctx)

    card = "#run-card-#{run.id}"
    assert has_element?(view, "#{card} [data-run-triggers]", "#{ctx.alice_name} 指派 等 2 条触发")
    assert has_element?(view, "#{card} [data-run-triggers-tip]", "#{ctx.carol_name} 手动运行")
    assert has_element?(view, "#{card} [data-run-triggers-tip]", "先补测试")
  end

  test "two windows: B sees the run A started, its title draft kept", ctx do
    {:ok, a, _html} = open(ctx)
    {:ok, b, _html} = open(ctx, ctx.carol)
    pid = b.pid

    render_click(b, "edit_field", %{"field" => "title"})
    render_change(b, "draft_field", %{"field" => "title", "value" => "我的草稿"})

    a |> element("#" <> Show.assignee_item_id("keel/dev")) |> render_click()

    render_click(a, "confirm_assign", %{
      "agent" => "keel/dev",
      "version" => version(ctx),
      "start" => "true"
    })

    eventually(fn -> has_element?(b, ~s(#task-runs-open [data-run-status="queued"])) end)
    assert b.pid == pid
    assert render(b) =~ "我的草稿"
  end

  test "an agent page shows the queued run", ctx do
    assign!(ctx)

    {:ok, view, _html} =
      live(log_in_user(ctx.conn, ctx.carol), "/w/#{ctx.workspace.slug}/agents/keel/dev")

    assert has_element?(view, ~s(#agent-runs-open [data-run-status="queued"]))
    assert {:ok, %{queued_runs: 1}} = Agents.get(ctx.alice_scope, "keel/dev")
  end

  defp version(ctx), do: elem(Tasks.get(ctx.alice_scope, ctx.task.ident), 1).lock_version
end
