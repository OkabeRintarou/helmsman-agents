defmodule HelmsmanWeb.RunLive.ShowTest do
  @moduledoc """
  Spec web-runs 运行页 (design D10) on a run driven through the daemon side of
  add-run-lifecycle (tasks 4.4).
  """
  use HelmsmanWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Helmsman.RunsFixtures
  import Helmsman.RunLifecycleFixtures
  import HelmsmanWeb.LiveHelpers

  alias Helmsman.Tasks

  setup %{conn: conn} do
    ctx = dispatch_fixture(%{access: "workspace"})
    {carol, _} = member_scope_fixture(ctx.workspace)
    {vic, _} = member_scope_fixture(ctx.workspace, :viewer)
    {:ok, task} = Tasks.create(ctx.alice_scope, ctx.project.key, %{title: "修复登录"})

    triggers = [
      trigger("assign", ctx.workspace, ctx.alice, ctx.agent),
      trigger("manual", ctx.workspace, carol, ctx.agent, %{"instructions" => "先补测试"})
    ]

    run =
      run_fixture(ctx.agent, %{
        task_id: task.id,
        triggers: triggers,
        root_initiator_user_id: ctx.alice.id
      })

    Map.merge(ctx, %{
      conn: conn,
      carol: carol,
      vic: vic,
      task: task,
      run: run,
      path: "/w/#{ctx.workspace.slug}/runs/#{run.id}"
    })
  end

  defp open(ctx, user), do: live(log_in_user(ctx.conn, user), ctx.path)

  test "分享运行链接: breadcrumb, title, every trigger, daemon and times", ctx do
    [_] = claim!(ctx.agent)
    start!(ctx.agent, ctx.run.id)
    {:ok, view, _html} = open(ctx, ctx.carol)

    assert page_title(view) =~ "运行 ##{ctx.run.id} · keel/dev"
    assert has_element?(view, ~s(nav[aria-label="面包屑"] a[href="/w/#{ctx.workspace.slug}/agents"]))
    assert has_element?(view, ~s(nav[aria-label="面包屑"] a), "keel/dev")
    assert has_element?(view, "h1", "运行 ##{ctx.run.id}")

    props = "#run-properties"
    assert has_element?(view, "#{props} [data-task]", ctx.task.ident)
    assert has_element?(view, ~s(#{props} [data-status] [data-run-status="running"]))
    assert has_element?(view, "#{props} [data-triggers] li", "指派")
    assert has_element?(view, "#{props} [data-triggers] li", "手动运行")
    assert has_element?(view, "#{props} [data-triggers] li", "说明：先补测试")
    assert has_element?(view, "#{props} [data-daemon]", "test-machine")
    assert has_element?(view, "#run-queued-at")
    assert has_element?(view, "#run-claimed-at")
    assert has_element?(view, "#run-started-at")
    refute has_element?(view, "#run-finished-at")
  end

  test "a run of another workspace is a 404", ctx do
    other = dispatch_fixture()
    foreign = run_fixture(other.agent)

    assert_raise HelmsmanWeb.NotFoundError, fn ->
      live(log_in_user(ctx.conn, ctx.alice), "/w/#{ctx.workspace.slug}/runs/#{foreign.id}")
    end
  end

  test "claimed → running → finished updates the badge and the times live", ctx do
    {:ok, member, _html} = open(ctx, ctx.carol)
    {:ok, viewer, _html} = open(ctx, ctx.vic)

    for view <- [member, viewer],
        do: assert(has_element?(view, ~s(#run-properties [data-run-status="queued"])))

    [_] = claim!(ctx.agent)

    for view <- [member, viewer] do
      eventually(fn -> has_element?(view, ~s(#run-properties [data-run-status="claimed"])) end)
      assert has_element?(view, "#run-claimed-at")
    end

    start!(ctx.agent, ctx.run.id)

    for view <- [member, viewer] do
      eventually(fn -> has_element?(view, ~s(#run-properties [data-run-status="running"])) end)
      assert has_element?(view, "#run-started-at")
    end

    finish!(ctx.agent, ctx.run.id)

    for view <- [member, viewer] do
      eventually(fn -> has_element?(view, ~s(#run-properties [data-run-status="succeeded"])) end)
      assert has_element?(view, "#run-finished-at")
    end
  end

  test "a viewer sees the summary only", ctx do
    [_] = claim!(ctx.agent)
    start!(ctx.agent, ctx.run.id)
    append!(ctx.agent, ctx.run.id, [1])

    {:ok, view, _html} = open(ctx, ctx.vic)
    assert has_element?(view, "#run-log-head")
    assert has_element?(view, "#run-log-viewer", "需要成员权限查看执行记录")
    refute has_element?(view, "#run-event-1")

    {:ok, view, _html} = open(ctx, ctx.carol)
    assert has_element?(view, "#run-event-1")
  end

  test "buttons by permission: the authorizing user stops and retries", ctx do
    [_] = claim!(ctx.agent)
    start!(ctx.agent, ctx.run.id)

    {:ok, view, _html} = open(ctx, ctx.alice)
    assert has_element?(view, "#run-cancel")
    refute has_element?(view, "#run-retry")

    for user <- [ctx.carol, ctx.vic] do
      {:ok, view, _html} = open(ctx, user)
      refute has_element?(view, "#run-cancel")
    end

    finish!(ctx.agent, ctx.run.id, :failed, %{failure_reason: :provider_quota})
    {:ok, view, _html} = open(ctx, ctx.alice)
    refute has_element?(view, "#run-cancel")
    assert has_element?(view, "#run-retry")
    assert has_element?(view, "#run-properties", "额度用尽")

    assert view |> element("#run-retry") |> render_click() =~ "已重新排队"
    [_, retry] = runs_of(ctx.task.id)

    assert has_element?(
             view,
             ~s(#run-properties a[href="/w/#{ctx.workspace.slug}/runs/#{retry.id}"])
           )

    for user <- [ctx.carol, ctx.vic] do
      {:ok, view, _html} = open(ctx, user)
      refute has_element?(view, "#run-retry")
    end
  end
end
