defmodule HelmsmanWeb.TaskLive.RunLogTest do
  @moduledoc """
  Spec web-runs 执行记录、运行页、停止与重试 (design D9, D9a, D10) with the run driven
  through the daemon side of add-run-lifecycle (`Helmsman.RunLifecycleFixtures`). The
  barrier test sets `:run_log_hook`, so not async.
  """
  use HelmsmanWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import HelmsmanWeb.PortalHelpers
  import Helmsman.RunsFixtures
  import Helmsman.RunLifecycleFixtures
  import HelmsmanWeb.LiveHelpers

  alias Helmsman.{Agents, Events, Repo, Runs, Tasks}
  alias Helmsman.Runs.RunEvent

  setup %{conn: conn} do
    on_exit(fn -> Application.delete_env(:helmsman, :run_log_hook) end)

    ctx = dispatch_fixture()
    {bob, _} = member_scope_fixture(ctx.workspace)
    {vic, _} = member_scope_fixture(ctx.workspace, :viewer)
    {:ok, task} = Tasks.create(ctx.alice_scope, ctx.project.key, %{title: "修复登录"})
    run = running_run!(ctx.agent, %{task_id: task.id, root_initiator_user_id: ctx.alice.id})

    Map.merge(ctx, %{
      conn: conn,
      bob: bob,
      vic: vic,
      task: task,
      run: run,
      path: "/w/#{ctx.workspace.slug}/t/#{task.ident}"
    })
  end

  defp put_events(ctx, range), do: append!(ctx.agent, ctx.run.id, Enum.to_list(range))

  # The wire form of an event, as in a `{:run_events, id, views}` notification.
  defp view_of(seq),
    do: %{seq: seq, type: "text", data: %{"text" => "第 #{seq} 条"}, at: DateTime.utc_now()}

  defp open_log(ctx, user \\ nil, run \\ nil),
    do: live(log_in_user(ctx.conn, user || ctx.alice), "#{ctx.path}?run=#{(run || ctx.run).id}")

  defp has_event?(view, seq), do: in_portal?(view, "run-log-modal", "#run-event-#{seq}")

  defp push_events(run, events),
    do: Events.broadcast(Events.topic(:run, run.id), {:run_events, run.id, events})

  defp subscribers(run),
    do: Registry.lookup(Helmsman.PubSub, "run:#{run.id}") |> Enum.map(&elem(&1, 0))

  describe "opening (D9)" do
    test "an event committed between the check and the subscription is in the read", ctx do
      put_events(ctx, 1..10)
      run_id = ctx.run.id
      agent = ctx.agent

      # Called after the check and before the subscription: the 11th is committed then,
      # and its notification goes to nobody.
      Application.put_env(:helmsman, :run_log_hook, fn ^run_id ->
        append!(agent, run_id, [11])
      end)

      {:ok, view, _html} = open_log(ctx)
      assert open?(view, "run-log-modal")
      assert has_event?(view, 11)

      put_events(ctx, 12..12)
      put_events(ctx, 13..13)
      render(view)
      for seq <- 1..13, do: assert(has_event?(view, seq))
    end

    test "a gap in the pushes is read from the database", ctx do
      put_events(ctx, 1..12)
      {:ok, view, _html} = open_log(ctx)

      # 13 and 14 are saved without a notification reaching the page; 15 is reported.
      Repo.insert_all(
        RunEvent,
        for(
          seq <- 13..14,
          do: %{
            run_id: ctx.run.id,
            seq: seq,
            type: "text",
            data: %{"text" => "第 #{seq} 条"},
            at: DateTime.utc_now()
          }
        )
      )

      set_run!(ctx.run.id, events_seq: 14)
      put_events(ctx, 15..15)
      html = view |> portal("run-log-modal") |> LazyHTML.to_html()

      positions =
        for seq <- [12, 13, 14, 15], do: :binary.match(html, ~s(id="run-event-#{seq}")) |> elem(0)

      assert positions == Enum.sort(positions)
    end

    test "overlapping events show once", ctx do
      put_events(ctx, 1..3)
      {:ok, view, _html} = open_log(ctx)

      push_events(ctx.run, [view_of(2), view_of(3), view_of(4)])
      html = view |> portal("run-log-modal") |> LazyHTML.to_html()
      assert length(String.split(html, ~s(id="run-event-3"))) == 2
      assert has_event?(view, 4)
    end

    test "an older summary does not replace a newer one", ctx do
      {:ok, view, _html} = open_log(ctx)
      {:ok, current} = Runs.get(ctx.alice_scope, ctx.run.id)
      old = %{current | status: "queued", updated_at: DateTime.add(current.updated_at, -60)}

      send(view.pid, {:run_updated, old})
      assert in_portal?(view, "run-log-modal", ~s(#run-log-head [data-run-status="running"]))
    end

    test "a run of another workspace subscribes to nothing", ctx do
      other = dispatch_fixture()
      foreign = run_fixture(other.agent, %{status: :running})

      {:ok, view, _html} = open_log(ctx, nil, foreign)
      assert in_portal?(view, "run-log-modal", "#run-log-not-found", "运行不存在")
      refute view.pid in subscribers(foreign)
    end

    test "a viewer sees the summary only and never subscribes to run:<id>", ctx do
      put_events(ctx, 1..1)
      {:ok, view, _html} = open_log(ctx, ctx.vic)

      assert in_portal?(view, "run-log-modal", "#run-log-head")
      assert in_portal?(view, "run-log-modal", "#run-log-viewer", "需要成员权限查看执行记录")
      refute has_event?(view, 1)
      refute view.pid in subscribers(ctx.run)
    end

    test "pruned events", ctx do
      finish!(ctx.agent, ctx.run.id)
      set_run!(ctx.run.id, events_pruned_at: DateTime.utc_now())
      {:ok, view, _html} = open_log(ctx)
      assert in_portal?(view, "run-log-modal", "#run-log-pruned", "30 天后清理")
    end
  end

  test "closing removes run from the address, unsubscribes and drops later events", ctx do
    put_events(ctx, 1..1)
    {:ok, view, _html} = open_log(ctx)
    assert view.pid in subscribers(ctx.run)

    render_patch(view, ctx.path)
    refute open?(view, "run-log-modal")
    refute view.pid in subscribers(ctx.run)

    send(view.pid, {:run_events, ctx.run.id, [view_of(2)]})
    refute has_event?(view, 2)
  end

  test "800 events: the latest 500, then the earlier ones on top", ctx do
    put_events(ctx, 1..800)
    {:ok, view, _html} = open_log(ctx)

    assert has_event?(view, 301)
    refute has_event?(view, 300)

    render_click(view, "run_log_earlier", %{})
    assert has_event?(view, 1)
    html = view |> portal("run-log-modal") |> LazyHTML.to_html()
    assert :binary.match(html, ~s(id="run-event-1")) < :binary.match(html, ~s(id="run-event-300"))

    assert :binary.match(html, ~s(id="run-event-300")) <
             :binary.match(html, ~s(id="run-event-301"))

    put_events(ctx, 801..801)
    assert has_event?(view, 801)
    assert has_event?(view, 1)
  end

  defp event_ids(view) do
    html = view |> portal("run-log-modal") |> LazyHTML.to_html()
    ~r/id="run-event-(\d+)"/ |> Regex.scan(html) |> Enum.map(&String.to_integer(List.last(&1)))
  end

  test "events trimmed by new ones can be loaded again (code-review-2)", ctx do
    put_events(ctx, 1..500)
    {:ok, view, _html} = open_log(ctx)
    refute in_portal?(view, "run-log-modal", "#run-log-earlier")

    put_events(ctx, 501..501)
    refute has_event?(view, 1)
    assert in_portal?(view, "run-log-modal", "#run-log-earlier")

    render_click(view, "run_log_earlier", %{})
    assert event_ids(view) == Enum.to_list(1..501)
  end

  test "after 800 then 801 the trimmed 301 comes back without duplicates", ctx do
    put_events(ctx, 1..800)
    {:ok, view, _html} = open_log(ctx)
    assert List.first(event_ids(view)) == 301

    put_events(ctx, 801..801)
    assert List.first(event_ids(view)) == 302

    render_click(view, "run_log_earlier", %{})
    ids = event_ids(view)
    assert ids == Enum.to_list(1..801)

    put_events(ctx, 802..802)
    assert event_ids(view) == Enum.to_list(1..802)
  end

  test "every event type renders, tool outputs named after their call", ctx do
    append!(ctx.agent, ctx.run.id, [
      event(1, :text, %{text: "**完成**了"}),
      event(2, :thinking, %{text: "想一想"}),
      event(3, :tool_call, %{call_id: "c1", name: "bash", input: "ls"}),
      event(4, :tool_result, %{call_id: "c1", output: "a.txt", is_error: true, truncated: true}),
      event(5, :tool_result, %{call_id: "zz", output: "?", is_error: false, truncated: false}),
      event(6, :result, %{text: "结果", success: true}),
      event(7, :error, %{reason: :provider_quota, message: "quota"}),
      event(8, :status, %{level: :warning, message: "慢"}),
      event(9, :session, %{session_id: "s-1"}),
      event(10, :usage, %{
        input_tokens: 1200,
        output_tokens: 340,
        cache_read_tokens: nil,
        cache_write_tokens: nil,
        cost_usd: nil
      })
    ])

    {:ok, view, _html} = open_log(ctx)
    m = "run-log-modal"
    assert in_portal?(view, m, "#run-event-1 strong", "完成")
    assert in_portal?(view, m, "#run-event-2 details summary", "思考")
    assert in_portal?(view, m, "#run-event-3 details [data-tool]", "bash")
    assert in_portal?(view, m, "#run-event-4 [data-tool-output]", "bash 的输出")
    assert in_portal?(view, m, "#run-event-4 [data-tool-output]", "输出已截断")
    assert in_portal?(view, m, "#run-event-4 details.border-danger")
    assert in_portal?(view, m, "#run-event-5 [data-tool-output]", "工具输出")
    assert in_portal?(view, m, "#run-event-6 [data-result]", "结果")
    assert in_portal?(view, m, "#run-event-7 [data-error]", "额度用尽")
    assert in_portal?(view, m, ~s(#run-event-8 [data-level="warning"]), "慢")
    assert in_portal?(view, m, "#run-event-9", "s-1")
    assert in_portal?(view, m, "#run-event-10 [data-usage]", "1.2k / 340")
    assert in_portal?(view, m, ~s(#run-log-events[phx-hook$="RunLogScroll"]))
  end

  test "a failed run's head shows the error to members only", ctx do
    finish!(ctx.agent, ctx.run.id, :failed, %{failure_reason: :provider_quota, error: "额度 boom"})

    {:ok, view, _html} = open_log(ctx, ctx.bob)
    assert in_portal?(view, "run-log-modal", "#run-log-head", "额度 boom")

    {:ok, view, _html} = open_log(ctx, ctx.vic)
    refute in_portal?(view, "run-log-modal", "#run-log-head", "额度 boom")
  end

  describe "the run page (D10)" do
    test "breadcrumb, title and properties", ctx do
      {:ok, view, _html} =
        live(log_in_user(ctx.conn, ctx.bob), "/w/#{ctx.workspace.slug}/runs/#{ctx.run.id}")

      assert page_title(view) =~ "运行 ##{ctx.run.id} · keel/dev"
      assert has_element?(view, ~s(nav[aria-label="面包屑"] a), "Agents")
      assert has_element?(view, ~s(nav[aria-label="面包屑"] a), "keel/dev")
      assert has_element?(view, "h1", "运行 ##{ctx.run.id}")
      assert has_element?(view, "#run-properties [data-task]", ctx.task.ident)
      assert has_element?(view, ~s(#run-properties [data-status] [data-run-status="running"]))
    end

    test "a run of another workspace is a 404", ctx do
      other = dispatch_fixture()
      foreign = run_fixture(other.agent, %{status: :running})

      assert_raise HelmsmanWeb.NotFoundError, fn ->
        live(log_in_user(ctx.conn, ctx.alice), "/w/#{ctx.workspace.slug}/runs/#{foreign.id}")
      end
    end
  end

  describe "停止与重试" do
    test "the authorizing user stops after confirming; others see no button", ctx do
      {:ok, view, _html} = live(log_in_user(ctx.conn, ctx.alice), ctx.path)
      card = "#run-card-#{ctx.run.id}"

      view |> element("#{card}-cancel") |> render_click()
      assert in_portal?(view, "stop-run", "#stop-run-description", "已有的改动会保留")
      render_click(view, "cancel_run", %{"id" => ctx.run.id})
      assert has_element?(view, ~s(#{card} [data-run-status="cancelling"]))
      refute has_element?(view, "#{card}-cancel")

      finish!(ctx.agent, ctx.run.id, :cancelled)
      eventually(fn -> has_element?(view, ~s(#{card} [data-run-status="cancelled"])) end)

      {:ok, view, _html} = live(log_in_user(ctx.conn, ctx.bob), ctx.path)
      refute has_element?(view, "#{card}-cancel")
      {:ok, view, _html} = live(log_in_user(ctx.conn, ctx.vic), ctx.path)
      refute has_element?(view, "#{card}-cancel")
    end

    test "refusals are explained", ctx do
      {:ok, view, _html} = live(log_in_user(ctx.conn, ctx.alice), ctx.path)

      finish!(ctx.agent, ctx.run.id, :failed, %{failure_reason: :provider_quota})
      assert render_click(view, "cancel_run", %{"id" => ctx.run.id}) =~ "运行已经结束"

      assert render_click(view, "retry_run", %{"id" => ctx.run.id}) =~ "已重新排队"
      [_, retried] = runs_of(ctx.task.id)

      # While the retry is queued, retrying again returns it; once claimed it is refused.
      assert render_click(view, "retry_run", %{"id" => ctx.run.id}) =~ "已重新排队"
      assert claim!(ctx.agent) == [retried.id]

      assert render_click(view, "retry_run", %{"id" => ctx.run.id}) =~
               "这次运行已经重试过（##{retried.id}）"

      other = running_run!(ctx.agent, %{task_id: ctx.task.id})
      finish!(ctx.agent, other.id, :failed, %{failure_reason: :provider_quota})

      {:ok, _} = Agents.disable(ctx.alice_scope, "keel/dev")
      assert render_click(view, "retry_run", %{"id" => other.id}) =~ "keel/dev 已停用"
      {:ok, _} = Agents.enable(ctx.alice_scope, "keel/dev")

      {:ok, _} = Tasks.transition(ctx.alice_scope, ctx.task.ident, :cancelled)
      assert render_click(view, "retry_run", %{"id" => other.id}) =~ "任务已验收或撤销，不能重试"
    end

    test "a failed run that was not retried offers 重试 on the run page", ctx do
      failed = running_run!(ctx.agent)
      finish!(ctx.agent, failed.id, :failed, %{failure_reason: :provider_quota})

      {:ok, view, _html} =
        live(log_in_user(ctx.conn, ctx.alice), "/w/#{ctx.workspace.slug}/runs/#{failed.id}")

      assert has_element?(view, "#run-retry")
      refute has_element?(view, "#run-cancel")
      assert has_element?(view, "#run-properties", "额度用尽")
    end
  end
end
