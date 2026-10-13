defmodule HelmsmanWeb.RunComponentsTest do
  @moduledoc "Design D12 (dispatch messages) and D13 (labels, formats)."
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Helmsman.Runs.Outcome
  alias HelmsmanWeb.RunComponents

  defp skipped(reason),
    do: Outcome.skipped(%Helmsman.Actors.Actor{name: "keel/dev"}, :assign, reason)

  describe "dispatch_message/1" do
    test "every row of D12" do
      rows = [
        {%Outcome{agent: "keel/dev", trigger: :assign, result: :queued, run_id: 1}, :info,
         "已派发给 keel/dev"},
        {%Outcome{agent: "keel/dev", trigger: :assign, result: :merged, run_id: 1}, :info,
         "已并入 keel/dev 排队中的运行"},
        {skipped(:not_started), :info, "已指派给 keel/dev，暂不开始"},
        {skipped(:task_closed), :warning, "没有启动 keel/dev：任务不在新建或进行中"},
        {skipped(:unauthorized), :warning, "没有启动 keel/dev：你无权触发它"},
        {skipped(:agent_disabled), :warning, "没有启动 keel/dev：它已停用"},
        {skipped(:agent_archived), :warning, "没有启动 keel/dev：它已归档"},
        {skipped(:no_runtime), :warning, "没有启动 keel/dev：它没有绑定运行时"},
        {skipped(:runtime_disabled), :warning, "没有启动 keel/dev：运行时已禁用"},
        {skipped(:daemon_outdated), :warning, "没有启动 keel/dev：它所在机器的守护进程版本过旧，请升级 helmsman 守护进程"},
        {skipped(:loop_detected), :warning, "没有启动 keel/dev：keel/dev 已在触发链上，为防止循环没有启动"},
        {skipped(:chain_too_long), :warning, "没有启动 keel/dev：触发链过长，为防止循环没有启动"},
        {skipped(:rate_limited), :warning, "没有启动 keel/dev：这个任务一小时内的运行次数已达上限"}
      ]

      for {outcome, level, text} <- rows do
        assert RunComponents.dispatch_message(outcome) == {level, text}
      end
    end

    test "deferred (add-dependency-dispatch): waits for the blocking tasks" do
      assert RunComponents.dispatch_message(%{
               agent: "keel/dev",
               result: :deferred,
               blocked_by: ["BOS-1", "BOS-2"]
             }) == {:info, "已指派给 keel/dev，等 BOS-1、BOS-2 完成后开始"}

      assert RunComponents.dispatch_message(%{agent: "keel/dev", result: "deferred"}) ==
               {:info, "已指派给 keel/dev，等前置任务完成后开始"}

      assert RunComponents.dispatch_flash([
               %{agent: "a", result: "deferred", blocked_by: ["BOS-1"]},
               %{agent: "b", result: "queued"}
             ]) == {:info, "已指派给 a，等 BOS-1 完成后开始；已派发给 b"}
    end

    test "an unknown result is logged, not a crash" do
      log =
        capture_log(fn ->
          assert RunComponents.dispatch_message(%{agent: "keel/dev", result: "later"}) ==
                   {:info, "已指派给 keel/dev"}
        end)

      assert log =~ "unknown dispatch result"
    end

    test "string forms (the MCP view) work too" do
      assert RunComponents.dispatch_message(%{
               agent: "a",
               result: "skipped",
               reason: "no_runtime"
             }) ==
               {:warning, "没有启动 a：它没有绑定运行时"}
    end

    test "several outcomes are one message; a warning makes it a warning" do
      assert RunComponents.dispatch_flash([]) == nil

      outcomes = [
        %Outcome{agent: "keel/dev", trigger: :assign, result: :queued, run_id: 1},
        Outcome.skipped(%Helmsman.Actors.Actor{name: "keel/qa"}, :assign, :no_runtime)
      ]

      assert RunComponents.dispatch_flash(outcomes) ==
               {:warning, "已派发给 keel/dev；没有启动 keel/qa：它没有绑定运行时"}
    end

    test "an unknown reason is logged" do
      log =
        capture_log(fn ->
          assert RunComponents.dispatch_message(%{
                   agent: "a",
                   result: :skipped,
                   reason: :new_thing
                 }) ==
                   {:warning, "没有启动 a"}
        end)

      assert log =~ "unknown dispatch reason"
    end
  end

  test "unavailable reasons" do
    assert RunComponents.unavailable_reason("keel/dev", :ok) == nil

    assert RunComponents.unavailable_reason("keel/dev", {:skipped, :unauthorized}) ==
             "你无权触发 keel/dev"

    assert RunComponents.unavailable_reason("keel/dev", {:skipped, :no_runtime}) ==
             "keel/dev 没有绑定运行时"

    assert RunComponents.unavailable_reason("keel/dev", {:skipped, :daemon_outdated}) ==
             "keel/dev 所在机器的守护进程版本过旧"

    assert RunComponents.dispatch_message(%{
             agent: "keel/claude-zai",
             result: "skipped",
             reason: "daemon_outdated"
           }) ==
             {:warning, "没有启动 keel/claude-zai：它所在机器的守护进程版本过旧，请升级 helmsman 守护进程"}
  end

  describe "D13" do
    test "every failure reason has a name and a hint" do
      for reason <- RunComponents.failure_reasons() do
        assert is_binary(RunComponents.failure_label(reason))
        assert is_binary(RunComponents.failure_hint(reason))
      end

      assert RunComponents.failure_label("provider_quota") == "额度用尽"
      assert RunComponents.failure_label(:runtime_offline) == "运行时离线"
      assert RunComponents.failure_hint("provider_auth") == "在运行时所在的机器上登录这个 CLI 后重试"
      assert RunComponents.failure_label("brand_new") == "未知错误"
    end

    test "trigger kinds and labels" do
      by = %{name: "alice", kind: "human"}
      assert RunComponents.trigger_label(%{kind: "assign", by: by}) == "alice 指派"
      assert RunComponents.trigger_label(%{kind: "manual", by: by}) == "alice 手动运行"
      assert RunComponents.trigger_label(%{kind: "retry", by: by, auto: false}) == "alice 重试"
      assert RunComponents.trigger_label(%{kind: "retry", by: nil, auto: true}) == "自动重试"
      assert RunComponents.trigger_label(%{kind: "reopen", by: by}) == "alice 打回"
      assert RunComponents.trigger_label(%{kind: "someday", by: by}) == "alice 其他触发"

      triggers = [%{kind: "assign", by: by}, %{kind: "manual", by: %{name: "carol"}}]
      assert RunComponents.trigger_summary(triggers) == "alice 指派 等 2 条触发"
    end

    test "usage and durations" do
      assert RunComponents.tokens(340) == "340"
      assert RunComponents.tokens(1234) == "1.2k"
      assert RunComponents.tokens(3_456_789) == "3.5M"

      assert RunComponents.usage_text(%{"input_tokens" => 1200, "output_tokens" => 340}) ==
               "1.2k / 340"

      assert RunComponents.usage_text(%{
               "input_tokens" => 1200,
               "output_tokens" => 340,
               "cost_usd" => 0.123
             }) == "1.2k / 340 · $0.12"

      assert RunComponents.usage_text(nil) == nil

      start = ~U[2026-10-12 10:00:00Z]

      assert RunComponents.duration_text(%{
               started_at: start,
               finished_at: DateTime.add(start, 42)
             }) ==
               "42 秒"

      assert RunComponents.duration_text(%{
               started_at: nil,
               claimed_at: start,
               finished_at: DateTime.add(start, 3780)
             }) == "1 小时 3 分"

      assert RunComponents.duration_text(%{started_at: start, finished_at: nil}) == nil
    end
  end

  # add-agent-conversation-ui D13: design runs.
  describe "design runs" do
    test "the trigger names the conversation's user, never the conversation" do
      design = %{kind: "design", by: %{name: "alice", kind: "human"}, at: nil, instructions: nil}
      assert RunComponents.trigger_label(design) == "alice 的创建对话"
      assert RunComponents.trigger_label(%{design | by: nil}) == "创建对话"
      assert RunComponents.trigger_kind(design) == "创建对话"
      assert RunComponents.trigger_summary([design]) == "alice 的创建对话"
    end

    test "never retried; not_retryable has its text" do
      design = %{kind: "design", by: nil, at: nil, instructions: nil}
      run = %{id: 1, status: "failed", retry_run_id: nil, triggers: [design]}
      assert HelmsmanWeb.RunData.design?(run)
      refute HelmsmanWeb.RunData.design?(%{run | triggers: [%{design | kind: "manual"}]})
      refute RunComponents.retryable?(%Helmsman.Accounts.Scope{}, run)

      assert HelmsmanWeb.RunActions.error_text(:not_retryable) ==
               "创建对话的运行不能重试，请在对话里重新发送"
    end
  end

  # add-collaboration-ui D11
  test "the steering and requester trigger names" do
    assert RunComponents.trigger_kind(%{kind: "steer"}) == "插话"
    assert RunComponents.trigger_kind(%{kind: "requested"}) == "回调提出方"
  end

  describe "squads and autopilots (add-squads-autopilots-ui D7)" do
    import Phoenix.LiveViewTest

    @scope %{workspace: %{slug: "acme"}}

    defp card(run) do
      base = %{
        id: 7,
        agent: "keel/fe",
        status: "queued",
        triggers: [],
        failure_reason: nil,
        inserted_at: ~U[2026-10-14 01:00:00Z]
      }

      render_component(&RunComponents.run_card/1,
        id: "run-7",
        run: Map.merge(base, run),
        scope: @scope
      )
    end

    test "trigger kinds and labels" do
      delegated = %{
        kind: "delegated",
        by: %{name: "keel/lead", kind: "agent"},
        instructions: "实现登录页"
      }

      assert RunComponents.trigger_label(delegated) == "keel/lead 委派"

      done = %{kind: "delegate_done", by: nil, member: %{name: "keel/fe", kind: "agent"}}
      assert RunComponents.trigger_label(done) == "keel/fe 的委派运行结束"
      assert RunComponents.trigger_kind(done) == "委派完成"

      auto = %{
        kind: "autopilot",
        by: nil,
        autopilot: %{id: 3, name: "weekly-audit"},
        source: "schedule"
      }

      assert RunComponents.trigger_label(auto) == "自动化 weekly-audit（定时）"
      assert RunComponents.trigger_label(%{auto | source: "manual"}) == "自动化 weekly-audit（手动）"

      assert RunComponents.trigger_label(%{auto | source: "webhook"}) ==
               "自动化 weekly-audit（webhook）"

      assert RunComponents.trigger_label(%{auto | autopilot: nil}) == "已删除的自动化（定时）"
      assert RunComponents.autopilot_path(auto, "acme") == "/w/acme/autopilots/3"
      assert RunComponents.autopilot_path(%{auto | autopilot: nil}, "acme") == nil
    end

    test "leader 的运行：卡片标出小队" do
      html =
        card(%{
          agent: "keel/lead",
          squad: %{id: 1, name: "web-team"},
          triggers: [%{kind: "assign", by: %{name: "alice", kind: "human"}}]
        })

      assert html =~ "以 web-team 的 leader 身份"
      assert html =~ ~s(href="/w/acme/squads/web-team")
      assert html =~ "alice 指派"
    end

    test "委派的卡片：悬停可见指示" do
      html =
        card(%{
          triggers: [
            %{kind: "delegated", by: %{name: "keel/lead", kind: "agent"}, instructions: "实现登录页"}
          ]
        })

      assert html =~ "keel/lead 委派"
      assert html =~ "实现登录页"
    end

    test "自动化的运行：链接、不能重试" do
      auto = %{
        kind: "autopilot",
        by: nil,
        autopilot: %{id: 3, name: "weekly-audit"},
        source: "schedule"
      }

      html = card(%{status: "failed", failure_reason: "cli_error", triggers: [auto]})

      assert html =~ ~s(href="/w/acme/autopilots/3")
      assert html =~ "自动化 weekly-audit（定时）"
      assert html =~ "自动化的运行不能重试，请在自动化页「立即运行」"

      deleted = card(%{triggers: [%{auto | autopilot: nil}]})
      assert deleted =~ "已删除的自动化（定时）"
      refute deleted =~ "/autopilots/"

      run = %{id: 1, status: "failed", retry_run_id: nil, triggers: [auto]}
      refute RunComponents.retryable?(%Helmsman.Accounts.Scope{}, run)
    end
  end
end
