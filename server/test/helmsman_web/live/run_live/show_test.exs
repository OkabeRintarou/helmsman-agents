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
  import Ecto.Query
  import Helmsman.AgentsFixtures
  import Helmsman.ProviderAccountsFixtures

  alias Helmsman.Daemons.Daemon
  alias Helmsman.{Repo, Tasks}

  setup %{conn: conn} do
    ctx = dispatch_fixture(%{access: "workspace"})
    {carol, _} = member_scope_fixture(ctx.workspace)
    {vic, _} = member_scope_fixture(ctx.workspace, :viewer)
    # Assigned to keel/dev (no run of its own): the `assign` trigger stays
    # valid when the run is claimed (add-squads decision 10).
    {:ok, task} =
      Tasks.create(ctx.alice_scope, ctx.project.key, %{
        title: "修复登录",
        assignee: "keel/dev",
        start: false
      })

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

  describe "运行页的供应商账号 (add-provider-accounts-ui D10)" do
    test "显示所用账号: the account of the claim, not of a later binding", ctx do
      daemon = daemon_of(ctx.agent)
      Repo.update_all(from(d in Daemon, where: d.id == ^daemon.id), set: [max_concurrency: 8])

      zai = provider_account_fixture(ctx.alice, %{name: "zai", api_key: "sk-zai-run"})
      volc = provider_account_fixture(ctx.alice, %{name: "volc"})

      managed_agent_fixture(ctx.alice_scope, %{
        name: "keel/claude-zai",
        runtime_id: profile(ctx.agent).runtime_id,
        provider_account_id: zai.id
      })

      agent = agent_actor(ctx.workspace, "keel/claude-zai")
      run = run_fixture(agent, %{root_initiator_user_id: ctx.alice.id})
      assert run.id in claim!(agent)

      {:ok, _} =
        Helmsman.Agents.update(ctx.alice_scope, "keel/claude-zai", %{provider_account_id: volc.id})

      {:ok, view, html} =
        live(log_in_user(ctx.conn, ctx.carol), "/w/#{ctx.workspace.slug}/runs/#{run.id}")

      assert has_element?(view, "#run-properties [data-provider-account]", "zai")
      refute has_element?(view, "#run-properties [data-provider-account]", "volc")
      # The account's icon, inferred from its address (add-actor-avatars D19).
      assert has_element?(view, "#run-properties [data-provider-account] [data-account-icon=zai]")

      assert has_element?(
               view,
               "#run-properties [data-provider-account] [data-account-host]",
               "api.z.ai"
             )

      refute html =~ "sk-zai-run"
    end

    test "未使用账号: no row", ctx do
      [_] = claim!(ctx.agent)
      {:ok, view, _html} = open(ctx, ctx.carol)
      assert has_element?(view, "#run-properties [data-daemon]")
      refute has_element?(view, "#run-properties [data-provider-account]")
    end
  end

  describe "运行的模型 (add-run-model)" do
    test "显示模型与图标: the model of the claim, not of a later change", ctx do
      {:ok, _} = Helmsman.Agents.update(ctx.alice_scope, "keel/dev", %{model: "gpt-5"})
      [_] = claim!(ctx.agent)
      {:ok, _} = Helmsman.Agents.update(ctx.alice_scope, "keel/dev", %{model: "glm-5.3"})

      {:ok, view, _html} = open(ctx, ctx.carol)
      assert has_element?(view, "#run-properties [data-model]", "gpt-5")
      assert has_element?(view, "#run-properties [data-model] [data-model-vendor=openai]")
      refute has_element?(view, "#run-properties [data-model]", "glm-5.3")
    end

    test "没有模型: no row", ctx do
      {:ok, view, _html} = open(ctx, ctx.carol)
      refute has_element?(view, "#run-properties [data-model]")
    end
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

  # add-squads-autopilots-ui D7: a run-only autopilot run has no task and no 重试; an
  # autopilot that no longer exists (or is not in this workspace) reads as deleted (R4).
  test "仅运行模式的运行: no task, not retryable; a missing autopilot reads as deleted", ctx do
    run =
      run_fixture(ctx.agent, %{
        status: :failed,
        failure_reason: :cli_error,
        finished_at: DateTime.utc_now(),
        triggers: [
          trigger("autopilot", ctx.workspace, ctx.alice, ctx.agent, %{
            "autopilot_id" => 3,
            "autopilot_run_id" => 9,
            "source" => "schedule"
          })
        ],
        root_initiator_user_id: ctx.alice.id
      })

    {:ok, view, _html} =
      live(log_in_user(ctx.conn, ctx.alice), "/w/#{ctx.workspace.slug}/runs/#{run.id}")

    assert has_element?(view, "#run-properties [data-no-task]", "无任务（自动化）")
    assert has_element?(view, "#run-properties [data-not-retryable]", "请在自动化页「立即运行」")
    assert has_element?(view, "#run-properties [data-triggers]", "已删除的自动化（定时）")
    refute has_element?(view, "#run-properties [data-triggers] [data-autopilot-link]")
    refute has_element?(view, "#run-retry")
  end

  # Code review 5 P2-1: an existing autopilot is named, with its source and a link (R4).
  test "a real autopilot run names and links its autopilot", %{conn: conn} do
    ctx = Helmsman.AutopilotsFixtures.autopilots_fixture()

    ap =
      Helmsman.AutopilotsFixtures.autopilot_fixture(ctx.alice_scope, %{
        name: "weekly-audit",
        mode: "run_only",
        project: nil
      })

    {:ok, record} = Helmsman.Autopilots.run_now(ctx.alice_scope, ap.id)
    path = "/w/#{ctx.workspace.slug}/runs/#{record.run_id}"
    {:ok, view, _html} = live(log_in_user(conn, ctx.alice), path)

    assert has_element?(view, "#run-properties [data-triggers]", "自动化 weekly-audit（手动）")

    assert has_element?(
             view,
             ~s(#run-properties [data-triggers] a[data-autopilot-link][href="/w/#{ctx.workspace.slug}/autopilots/#{ap.id}"])
           )

    refute has_element?(view, "#run-retry")
  end
end
