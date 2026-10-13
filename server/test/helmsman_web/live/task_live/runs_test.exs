defmodule HelmsmanWeb.TaskLive.RunsTest do
  @moduledoc """
  Spec web-runs 任务详情页的运行区、运行卡片、停止与重试、运行的实时刷新 (design D8), with runs
  driven through the daemon side of add-run-lifecycle where the scenario has one.
  """
  use HelmsmanWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Helmsman.RunsFixtures
  import Helmsman.RunLifecycleFixtures
  import HelmsmanWeb.PortalHelpers

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

  import HelmsmanWeb.LiveHelpers

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

  @t0 ~U[2026-10-01 08:00:00.000000Z]

  defp at(seconds), do: DateTime.add(@t0, seconds, :second)

  # A run of the task that ended at `at(n + 30)`, created at `at(n)`.
  defp ended_run(ctx, n, status \\ :cancelled) do
    run_fixture(ctx.agent, %{
      task_id: ctx.task.id,
      status: status,
      inserted_at: at(n),
      finished_at: at(n + 30)
    })
  end

  defp history_ids(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#task-runs-history > [id^=task-run-]")
    |> LazyHTML.attribute("id")
    |> Enum.map(&(&1 |> String.replace_prefix("task-run-", "") |> String.to_integer()))
  end

  describe "the section with real runs (4.1)" do
    test "进行中与历史: the running card first, the newest 3, 显示全部（5）", ctx do
      ended = for n <- 1..5, do: ended_run(ctx, n * 60, :succeeded)
      running = running_run!(ctx.agent, %{task_id: ctx.task.id})
      {:ok, view, _html} = open(ctx)

      assert has_element?(
               view,
               ~s(#task-runs-open #run-card-#{running.id} [data-run-status="running"])
             )

      recent = ended |> Enum.reverse() |> Enum.take(3)
      for run <- recent, do: assert(has_element?(view, "#task-runs-recent #run-card-#{run.id}"))
      refute has_element?(view, "#run-card-#{hd(ended).id}")
      assert has_element?(view, "#task-runs-show-all", "显示全部（5）")

      view |> element("#task-runs-show-all") |> render_click()
      assert history_ids(view) == Enum.map(Enum.reverse(ended), & &1.id)
    end

    test "60 stopped runs after a running one: still shown, marker, 验收 locked", ctx do
      running = running_run!(ctx.agent, %{task_id: ctx.task.id, inserted_at: at(0)})
      {:ok, _} = Tasks.transition(ctx.alice_scope, ctx.task.ident, :in_progress)
      {:ok, _} = Tasks.transition(ctx.alice_scope, ctx.task.ident, :done)
      for n <- 1..60, do: ended_run(ctx, n * 60)

      {:ok, view, _html} = open(ctx)
      assert has_element?(view, "#run-card-#{running.id}")
      assert has_element?(view, "#task-working", "keel/dev 正在处理")
      assert has_element?(view, ~s(#transition-verified[aria-disabled="true"]))
      assert has_element?(view, "#task-runs-show-all", "显示全部（60）")

      view |> element("#task-runs-show-all") |> render_click()
      assert length(history_ids(view)) == 20
      view |> element("#task-runs-more") |> render_click()
      view |> element("#task-runs-more") |> render_click()
      assert length(history_ids(view)) == 60
      refute has_element?(view, "#task-runs-more")

      # The total becomes 61: the expanded window of 60 gets 加载更多, the collapsed one
      # shows 显示全部（61）.
      finish!(ctx.agent, running.id)
      eventually(fn -> has_element?(view, "#task-runs-more") end)
      view |> element("#task-runs-collapse") |> render_click()
      assert has_element?(view, "#task-runs-show-all", "显示全部（61）")
    end

    test "an old run ending later takes its place; every row once", ctx do
      old = running_run!(ctx.agent, %{task_id: ctx.task.id, inserted_at: at(0)})
      ended = for n <- 1..60, do: ended_run(ctx, n * 60)

      {:ok, view, _html} = open(ctx)
      view |> element("#task-runs-show-all") |> render_click()
      view |> element("#task-runs-more") |> render_click()
      shown = history_ids(view)
      assert length(shown) == 40

      finish!(ctx.agent, old.id)
      eventually(fn -> not has_element?(view, "#task-runs-open #run-card-#{old.id}") end)
      assert history_ids(view) == shown

      view |> element("#task-runs-more") |> render_click()
      view |> element("#task-runs-more") |> render_click()
      assert history_ids(view) == Enum.map(Enum.reverse(ended), & &1.id) ++ [old.id]
    end

    test "a running card: 第 2 次尝试, 开始于, the trigger and the authorizer", ctx do
      triggers = [trigger("manual", ctx.workspace, ctx.carol, ctx.agent)]

      run =
        running_run!(ctx.agent, %{
          task_id: ctx.task.id,
          attempt: 2,
          triggers: triggers,
          root_initiator_user_id: ctx.alice.id
        })

      set_run!(run.id, started_at: DateTime.add(DateTime.utc_now(), -180))
      {:ok, view, _html} = open(ctx)
      card = "#run-card-#{run.id}"

      assert has_element?(view, ~s(#{card} [data-run-status="running"]), "运行中")
      assert has_element?(view, "#{card} [data-run-triggers]", "#{ctx.carol_name} 手动运行")
      assert has_element?(view, "#{card} [data-run-attempt]", "第 2 次尝试")
      assert has_element?(view, "#{card} [data-run-time]", "开始于")
      assert has_element?(view, "#{card} [data-run-time]", "3 分钟前")
      assert has_element?(view, "#{card} [data-run-authorizer]", "授权来源：")
    end

    test "a failed card: 额度用尽 with its hint, 重试 for the authorizing user", ctx do
      run = running_run!(ctx.agent, %{task_id: ctx.task.id, root_initiator_user_id: ctx.alice.id})
      finish!(ctx.agent, run.id, :failed, %{failure_reason: :provider_quota})
      {:ok, view, _html} = open(ctx)
      card = "#run-card-#{run.id}"

      assert has_element?(view, ~s(#{card} [data-run-status="failed"]))
      assert has_element?(view, "#{card} [data-run-failure]", "额度用尽")
      assert has_element?(view, "#{card}-retry")

      {:ok, view, _html} = open(ctx, ctx.carol)
      refute has_element?(view, "#{card}-retry")
    end
  end

  describe "停止与重试 (4.2)" do
    test "stopping a running run: 停止中, then 已停止 when the daemon reports", ctx do
      run = running_run!(ctx.agent, %{task_id: ctx.task.id, root_initiator_user_id: ctx.alice.id})
      {:ok, view, _html} = open(ctx)
      card = "#run-card-#{run.id}"

      view |> element("#{card}-cancel") |> render_click()
      assert in_portal?(view, "stop-run", "#stop-run-description", "已有的改动会保留")
      render_click(view, "cancel_run", %{"id" => run.id})
      assert has_element?(view, ~s(#{card} [data-run-status="cancelling"]))
      assert has_element?(view, card, "正在停止…")
      refute has_element?(view, "#{card}-cancel")

      finish!(ctx.agent, run.id, :cancelled)
      eventually(fn -> has_element?(view, ~s(#{card} [data-run-status="cancelled"])) end)
    end

    test "an unrelated member and a viewer see neither button", ctx do
      run = running_run!(ctx.agent, %{task_id: ctx.task.id, root_initiator_user_id: ctx.alice.id})

      failed =
        running_run!(ctx.agent, %{root_initiator_user_id: ctx.alice.id, task_id: ctx.task.id})

      finish!(ctx.agent, failed.id, :failed, %{failure_reason: :provider_auth})
      {vic, _} = member_scope_fixture(ctx.workspace, :viewer)

      for user <- [ctx.carol, vic] do
        {:ok, view, _html} = open(ctx, user)
        assert has_element?(view, "#run-card-#{run.id}")
        refute has_element?(view, "#run-card-#{run.id}-cancel")
        refute has_element?(view, "#run-card-#{failed.id}-retry")
      end
    end

    test "retrying a failed run: 已重新排队, alice 重试, 已重试 → #new", ctx do
      run = running_run!(ctx.agent, %{task_id: ctx.task.id, root_initiator_user_id: ctx.alice.id})
      finish!(ctx.agent, run.id, :failed, %{failure_reason: :provider_auth})
      {:ok, view, _html} = open(ctx)

      assert view |> element("#run-card-#{run.id}-retry") |> render_click() =~ "已重新排队"
      [_, retry] = runs_of(ctx.task.id)

      assert has_element?(view, ~s(#run-card-#{retry.id} [data-run-status="queued"]))

      assert has_element?(
               view,
               "#run-card-#{retry.id} [data-run-triggers]",
               "#{ctx.alice_name} 重试"
             )

      assert has_element?(view, "#run-card-#{retry.id} [data-run-retry-of]", "重试自 ##{run.id}")
      assert has_element?(view, "#run-card-#{run.id} [data-run-retried]", "已重试 → ##{retry.id}")
      refute has_element?(view, "#run-card-#{run.id}-retry")
    end

    test "stopping a run that just ended: 运行已经结束 and the latest status", ctx do
      run = running_run!(ctx.agent, %{task_id: ctx.task.id, root_initiator_user_id: ctx.alice.id})
      {:ok, view, _html} = open(ctx)
      view |> element("#run-card-#{run.id}-cancel") |> render_click()

      # The daemon reports the end; the click arrives before the page reloads.
      finish!(ctx.agent, run.id, :succeeded)
      assert render_click(view, "cancel_run", %{"id" => run.id}) =~ "运行已经结束"
      assert has_element?(view, ~s(#run-card-#{run.id} [data-run-status="succeeded"]))
    end

    test "a refused retry names the agent", ctx do
      run = running_run!(ctx.agent, %{task_id: ctx.task.id, root_initiator_user_id: ctx.alice.id})
      finish!(ctx.agent, run.id, :failed, %{failure_reason: :provider_auth})
      {:ok, view, _html} = open(ctx)

      # Archiving disables too, so the domain refuses with agent_disabled first.
      {:ok, _} = Agents.archive(ctx.alice_scope, "keel/dev")
      assert render_click(view, "retry_run", %{"id" => run.id}) =~ "keel/dev 已停用"
      assert [_] = runs_of(ctx.task.id)
    end
  end
end
