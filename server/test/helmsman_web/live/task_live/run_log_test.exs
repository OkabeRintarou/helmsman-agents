defmodule HelmsmanWeb.TaskLive.RunLogTest do
  @moduledoc """
  Spec web-runs 执行记录、运行页、停止与重试 (design D9, D9a, D10) against the functions of
  add-run-lifecycle (`Runs.list_events/3`, `can?/3`, `cancel/2`, `retry/2`, the summary's
  `initiator`), stood in for by `StubRuns` until that change is merged. Changes the
  application environment, so not async.
  """
  use HelmsmanWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import HelmsmanWeb.PortalHelpers
  import Helmsman.RunsFixtures

  alias Helmsman.{Events, Runs, Tasks}

  defmodule StubRuns do
    @moduledoc false
    # Events of each run in :persistent_term; the summary gets `initiator` and
    # `agent_owner_id`, and members get `error`.
    alias Helmsman.Runs

    def events(id), do: :persistent_term.get({__MODULE__, id}, [])
    def put_events(id, events), do: :persistent_term.put({__MODULE__, id}, events)
    def pruned(id), do: :persistent_term.put({__MODULE__, :pruned, id}, true)

    def get(scope, id) do
      with {:ok, summary} <- Runs.get(scope, id) do
        run = Helmsman.Repo.get!(Helmsman.Runs.Run, id) |> Helmsman.Repo.preload(:agent)

        {:ok,
         Map.merge(summary, %{
           initiator: %{id: run.root_initiator_user_id, name: "alice"},
           agent_owner_id: run.agent.owner_id,
           retry_run_id: nil,
           error: if(scope.role in [:owner, :admin, :member], do: "boom")
         })}
      end
    end

    def list_open(scope, {:task, ident}, _opts) do
      {:ok, runs} = Runs.list_for_task(scope, ident)
      runs = Enum.map(runs, &elem(__MODULE__.get(scope, &1.id), 1))
      pending = Enum.filter(runs, &(&1.status in ~w(queued deferred)))
      active = Enum.filter(runs, &(&1.status in ~w(claimed running cancelling)))
      {:ok, %{active: active, pending: pending, pending_total: length(pending)}}
    end

    def list_finished(_scope, _target, _opts), do: {:ok, %{runs: [], total: 0}}

    def list_events(_scope, id, opts) do
      all = events(id)
      last = all |> Enum.map(& &1.seq) |> Enum.max(fn -> 0 end)
      limit = opts[:limit] || 500

      events =
        cond do
          opts[:latest] ->
            Enum.take(all, -limit)

          opts[:before_seq] ->
            all |> Enum.filter(&(&1.seq < opts[:before_seq])) |> Enum.take(-limit)

          true ->
            all |> Enum.filter(&(&1.seq > (opts[:after_seq] || 0))) |> Enum.take(limit)
        end

      if :persistent_term.get({__MODULE__, :pruned, id}, false),
        do: {:ok, %{events: [], pruned: true, last_seq: last}},
        else: {:ok, %{events: events, pruned: false, last_seq: last}}
    end

    def can?(scope, _action, summary),
      do:
        scope.role in [:owner, :admin] or
          scope.user.id in [summary.initiator.id, summary.agent_owner_id]

    def cancel(_scope, id), do: :persistent_term.get({__MODULE__, :cancel}, {:ok, %{id: id}})
    def retry(_scope, id), do: :persistent_term.get({__MODULE__, :retry}, {:ok, %{id: id}})
  end

  setup %{conn: conn} do
    previous = Application.get_env(:helmsman, HelmsmanWeb.RunData)
    Application.put_env(:helmsman, HelmsmanWeb.RunData, runs: StubRuns)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:helmsman, HelmsmanWeb.RunData, previous),
        else: Application.delete_env(:helmsman, HelmsmanWeb.RunData)

      Application.delete_env(:helmsman, :run_log_hook)

      for {key, _} <- :persistent_term.get(),
          match?({StubRuns, _}, key) or match?({StubRuns, _, _}, key),
          do: :persistent_term.erase(key)
    end)

    ctx = dispatch_fixture()
    {bob, _} = member_scope_fixture(ctx.workspace)
    {vic, _} = member_scope_fixture(ctx.workspace, :viewer)
    {:ok, task} = Tasks.create(ctx.alice_scope, ctx.project.key, %{title: "修复登录"})

    run =
      run_fixture(ctx.agent, %{
        task_id: task.id,
        status: :running,
        root_initiator_user_id: ctx.alice.id
      })

    Map.merge(ctx, %{
      conn: conn,
      bob: bob,
      vic: vic,
      task: task,
      run: run,
      path: "/w/#{ctx.workspace.slug}/t/#{task.ident}"
    })
  end

  defp event(seq, type \\ "text", data \\ nil),
    do: %{
      seq: seq,
      type: type,
      data: data || %{"text" => "第 #{seq} 条"},
      at: ~U[2026-10-12 08:00:00Z]
    }

  defp open_log(ctx, user \\ nil, run \\ nil),
    do: live(log_in_user(ctx.conn, user || ctx.alice), "#{ctx.path}?run=#{(run || ctx.run).id}")

  defp has_event?(view, seq), do: in_portal?(view, "run-log-modal", "#run-event-#{seq}")

  defp push_events(run, events),
    do: Events.broadcast(Events.topic(:run, run.id), {:run_events, run.id, events})

  defp subscribers(run),
    do: Registry.lookup(Helmsman.PubSub, "run:#{run.id}") |> Enum.map(&elem(&1, 0))

  describe "opening (D9)" do
    test "an event committed between the check and the subscription is in the read", ctx do
      StubRuns.put_events(ctx.run.id, Enum.map(1..10, &event/1))
      run_id = ctx.run.id

      Application.put_env(:helmsman, :run_log_hook, fn ^run_id ->
        StubRuns.put_events(run_id, Enum.map(1..11, &event/1))
      end)

      {:ok, view, _html} = open_log(ctx)
      assert open?(view, "run-log-modal")
      assert has_event?(view, 11)

      push_events(ctx.run, [event(12)])
      push_events(ctx.run, [event(13)])
      render(view)
      for seq <- 1..13, do: assert(has_event?(view, seq))
    end

    test "a gap in the pushes is read from the database", ctx do
      StubRuns.put_events(ctx.run.id, Enum.map(1..12, &event/1))
      {:ok, view, _html} = open_log(ctx)
      StubRuns.put_events(ctx.run.id, Enum.map(1..15, &event/1))

      send(view.pid, {:run_events, ctx.run.id, [event(15)]})
      html = view |> portal("run-log-modal") |> LazyHTML.to_html()

      positions =
        for seq <- [12, 13, 14, 15], do: :binary.match(html, ~s(id="run-event-#{seq}")) |> elem(0)

      assert positions == Enum.sort(positions)
    end

    test "overlapping events show once", ctx do
      StubRuns.put_events(ctx.run.id, Enum.map(1..3, &event/1))
      {:ok, view, _html} = open_log(ctx)

      push_events(ctx.run, [event(2), event(3), event(4)])
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
      StubRuns.put_events(ctx.run.id, [event(1)])
      {:ok, view, _html} = open_log(ctx, ctx.vic)

      assert in_portal?(view, "run-log-modal", "#run-log-head")
      assert in_portal?(view, "run-log-modal", "#run-log-viewer", "需要成员权限查看执行记录")
      refute has_event?(view, 1)
      refute view.pid in subscribers(ctx.run)
    end

    test "pruned events", ctx do
      StubRuns.pruned(ctx.run.id)
      {:ok, view, _html} = open_log(ctx)
      assert in_portal?(view, "run-log-modal", "#run-log-pruned", "30 天后清理")
    end
  end

  test "closing removes run from the address, unsubscribes and drops later events", ctx do
    StubRuns.put_events(ctx.run.id, [event(1)])
    {:ok, view, _html} = open_log(ctx)
    assert view.pid in subscribers(ctx.run)

    render_patch(view, ctx.path)
    refute open?(view, "run-log-modal")
    refute view.pid in subscribers(ctx.run)

    send(view.pid, {:run_events, ctx.run.id, [event(2)]})
    refute has_event?(view, 2)
  end

  test "800 events: the latest 500, then the earlier ones on top", ctx do
    StubRuns.put_events(ctx.run.id, Enum.map(1..800, &event/1))
    {:ok, view, _html} = open_log(ctx)

    assert has_event?(view, 301)
    refute has_event?(view, 300)

    render_click(view, "run_log_earlier", %{})
    assert has_event?(view, 1)
    html = view |> portal("run-log-modal") |> LazyHTML.to_html()
    assert :binary.match(html, ~s(id="run-event-1")) < :binary.match(html, ~s(id="run-event-300"))

    assert :binary.match(html, ~s(id="run-event-300")) <
             :binary.match(html, ~s(id="run-event-301"))

    push_events(ctx.run, [event(801)])
    assert has_event?(view, 801)
    assert has_event?(view, 1)
  end

  defp event_ids(view) do
    html = view |> portal("run-log-modal") |> LazyHTML.to_html()
    ~r/id="run-event-(\d+)"/ |> Regex.scan(html) |> Enum.map(&String.to_integer(List.last(&1)))
  end

  test "events trimmed by new ones can be loaded again (code-review-2)", ctx do
    StubRuns.put_events(ctx.run.id, Enum.map(1..500, &event/1))
    {:ok, view, _html} = open_log(ctx)
    refute in_portal?(view, "run-log-modal", "#run-log-earlier")

    StubRuns.put_events(ctx.run.id, Enum.map(1..501, &event/1))
    push_events(ctx.run, [event(501)])
    refute has_event?(view, 1)
    assert in_portal?(view, "run-log-modal", "#run-log-earlier")

    render_click(view, "run_log_earlier", %{})
    assert event_ids(view) == Enum.to_list(1..501)
  end

  test "after 800 then 801 the trimmed 301 comes back without duplicates", ctx do
    StubRuns.put_events(ctx.run.id, Enum.map(1..800, &event/1))
    {:ok, view, _html} = open_log(ctx)
    assert List.first(event_ids(view)) == 301

    StubRuns.put_events(ctx.run.id, Enum.map(1..801, &event/1))
    push_events(ctx.run, [event(801)])
    assert List.first(event_ids(view)) == 302

    render_click(view, "run_log_earlier", %{})
    ids = event_ids(view)
    assert ids == Enum.to_list(1..801)

    push_events(ctx.run, [event(802)])
    assert event_ids(view) == Enum.to_list(1..802)
  end

  test "every event type renders, tool outputs named after their call", ctx do
    StubRuns.put_events(ctx.run.id, [
      event(1, "text", %{"text" => "**完成**了"}),
      event(2, "thinking", %{"text" => "想一想"}),
      event(3, "tool_call", %{"call_id" => "c1", "name" => "bash", "input" => "ls"}),
      event(4, "tool_result", %{
        "call_id" => "c1",
        "output" => "a.txt",
        "is_error" => true,
        "truncated" => true
      }),
      event(5, "tool_result", %{
        "call_id" => "zz",
        "output" => "?",
        "is_error" => false,
        "truncated" => false
      }),
      event(6, "result", %{"text" => "结果", "success" => true}),
      event(7, "error", %{"reason" => "provider_quota", "message" => "quota"}),
      event(8, "status", %{"level" => "warning", "message" => "慢"}),
      event(9, "session", %{"session_id" => "s-1"}),
      event(10, "usage", %{"input_tokens" => 1200, "output_tokens" => 340, "cost_usd" => nil})
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
    # A failed run's head shows the error to members.
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

      {:ok, view, _html} = live(log_in_user(ctx.conn, ctx.bob), ctx.path)
      refute has_element?(view, "#{card}-cancel")
      {:ok, view, _html} = live(log_in_user(ctx.conn, ctx.vic), ctx.path)
      refute has_element?(view, "#{card}-cancel")
    end

    test "refusals are explained", ctx do
      {:ok, view, _html} = live(log_in_user(ctx.conn, ctx.alice), ctx.path)

      :persistent_term.put({StubRuns, :cancel}, {:error, :already_finished})
      assert render_click(view, "cancel_run", %{"id" => ctx.run.id}) =~ "运行已经结束"

      for {reason, text} <- [
            {{:already_retried, 99}, "这次运行已经重试过（#99）"},
            {:task_closed, "任务已验收或撤销，不能重试"},
            {:agent_disabled, "Agent 已停用"}
          ] do
        :persistent_term.put({StubRuns, :retry}, {:error, reason})
        assert render_click(view, "retry_run", %{"id" => ctx.run.id}) =~ text
      end

      :persistent_term.put({StubRuns, :retry}, {:ok, %{id: 1}})
      assert render_click(view, "retry_run", %{"id" => ctx.run.id}) =~ "已重新排队"
    end

    test "a failed run that was not retried offers 重试 on the run page", ctx do
      failed = run_fixture(ctx.agent, %{status: :failed, failure_reason: :provider_quota})

      {:ok, view, _html} =
        live(log_in_user(ctx.conn, ctx.alice), "/w/#{ctx.workspace.slug}/runs/#{failed.id}")

      assert has_element?(view, "#run-retry")
      refute has_element?(view, "#run-cancel")
      assert has_element?(view, "#run-properties", "额度用尽")
    end
  end
end
