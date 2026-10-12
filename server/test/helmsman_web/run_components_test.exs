defmodule HelmsmanWeb.RunComponentsTest do
  @moduledoc "Design D12 (dispatch messages) and D13 (labels, formats)."
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Helmsman.Runs.Outcome
  alias HelmsmanWeb.RunComponents

  defp skipped(reason), do: Outcome.skipped("keel/dev", :assign, reason)

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
        {skipped(:loop_detected), :warning, "没有启动 keel/dev：keel/dev 已在触发链上，为防止循环没有启动"},
        {skipped(:chain_too_long), :warning, "没有启动 keel/dev：触发链过长，为防止循环没有启动"},
        {skipped(:rate_limited), :warning, "没有启动 keel/dev：这个任务一小时内的运行次数已达上限"}
      ]

      for {outcome, level, text} <- rows do
        assert RunComponents.dispatch_message(outcome) == {level, text}
      end
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
        Outcome.skipped("keel/qa", :assign, :no_runtime)
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
end
