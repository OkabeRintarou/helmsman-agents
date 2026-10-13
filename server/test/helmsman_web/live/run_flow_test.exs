defmodule HelmsmanWeb.RunFlowTest do
  @moduledoc """
  Spec web-runs M5 端到端「自动测试的链路」(tasks 6.1): assigning a managed agent in the
  browser, the daemon side of the run lifecycle, and two task pages that follow every
  step live without reconnecting.
  """
  use HelmsmanWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Helmsman.RunsFixtures
  import Helmsman.RunLifecycleFixtures
  import HelmsmanWeb.LiveHelpers
  import HelmsmanWeb.PortalHelpers

  alias Helmsman.{Feedback, Runs, Tasks}
  alias Helmsman.Runs.RunTokens
  alias HelmsmanWeb.TaskLive.Show

  setup %{conn: conn} do
    ctx = dispatch_fixture(%{access: "workspace"})
    {carol, _} = member_scope_fixture(ctx.workspace)
    {:ok, task} = Tasks.create(ctx.alice_scope, ctx.project.key, %{title: "修复登录"})

    Map.merge(ctx, %{
      conn: conn,
      carol: carol,
      task: task,
      path: "/w/#{ctx.workspace.slug}/t/#{task.ident}"
    })
  end

  defp status_of(view, status),
    do: has_element?(view, ~s(#task-runs-open [data-run-status="#{status}"]))

  test "assign → claim → start → events → feedback and done → finish", ctx do
    {:ok, a, _html} = live(log_in_user(ctx.conn, ctx.alice), ctx.path)
    {:ok, b, _html} = live(log_in_user(ctx.conn, ctx.carol), ctx.path)
    pids = {a.pid, b.pid}

    # Assign keel/dev in the browser and start.
    a |> element("#" <> Show.assignee_item_id("keel/dev")) |> render_click()
    {:ok, task} = Tasks.get(ctx.alice_scope, ctx.task.ident)

    render_click(a, "confirm_assign", %{
      "agent" => "keel/dev",
      "version" => task.lock_version,
      "start" => "true"
    })

    [run] = runs_of(ctx.task.id)
    for view <- [a, b], do: eventually(fn -> status_of(view, "queued") end)

    # The daemon claims it: 准备中 on both pages.
    {:ok, [spec]} = Runs.claim(dctx(ctx.agent), "http://localhost:4000")
    assert spec.run_id == run.id

    for view <- [a, b] do
      eventually(fn -> status_of(view, "claimed") end)
      assert has_element?(view, ~s(#run-card-#{run.id} [data-run-status="claimed"]), "准备中")
    end

    # It starts; the auto-claim side effect moves the task to 进行中.
    start!(ctx.agent, run.id)
    Oban.drain_queue(queue: :runs)

    for view <- [a, b] do
      eventually(fn -> status_of(view, "running") end)
      eventually(fn -> has_element?(view, ~s(#task-status [data-status="in_progress"])) end)
      assert has_element?(view, "#task-working", "keel/dev 正在处理")
    end

    # The log, opened on A, shows a reported text.
    a |> element("#task-working") |> render_click()
    assert_patch(a, "#{ctx.path}?run=#{run.id}")
    append!(ctx.agent, run.id, [event(1, :text, %{text: "正在读代码"})])
    eventually(fn -> in_portal?(a, "run-log-modal", "#run-event-1", "正在读代码") end)

    # The agent, with its run token, writes a comment and completes the task.
    {:ok, run_scope} = RunTokens.scope(spec.mcp.token)
    {:ok, _} = Feedback.add(run_scope, ctx.task.ident, %{kind: "comment", content: "已修复"})
    {:ok, _} = Tasks.transition(run_scope, ctx.task.ident, :done, %{})

    for view <- [a, b] do
      eventually(fn -> has_element?(view, ~s(#task-status [data-status="done"]), "待验收") end)
      eventually(fn -> render(view) =~ "已修复" end)
      assert has_element?(view, ~s(#transition-verified[aria-disabled="true"]))
    end

    # The run ends: 已结束, no marker, 验收 usable.
    finish!(ctx.agent, run.id)

    for view <- [a, b] do
      eventually(fn ->
        has_element?(view, ~s(#run-card-#{run.id} [data-run-status="succeeded"]))
      end)

      eventually(fn -> not has_element?(view, "#task-working") end)
      assert has_element?(view, "#transition-verified")
      refute has_element?(view, ~s(#transition-verified[aria-disabled]))
    end

    assert {a.pid, b.pid} == pids
  end
end
