defmodule HelmsmanWeb.TaskTransitionsTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Helmsman.Tasks.StateMachine
  alias HelmsmanWeb.TaskLive.TransitionErrors
  alias HelmsmanWeb.TaskTransitions

  defp summary(status) do
    status
    |> TaskTransitions.buttons(StateMachine.allowed(String.to_atom(status)))
    |> Enum.map(&{&1.to, &1.label, &1.kind, &1.primary?})
  end

  test "buttons per status follow the table, primary last" do
    assert summary("new") == [
             {"rejected", "拒绝", :reason, false},
             {"cancelled", "撤销", :reason, false},
             {"in_progress", "开始", :direct, true}
           ]

    assert summary("in_progress") == [
             {"rejected", "拒绝", :reason, false},
             {"cancelled", "撤销", :reason, false},
             {"done", "完成", :evidence, true}
           ]

    assert summary("done") == [
             {"in_progress", "打回", :reason, false},
             {"verified", "验收", :evidence, true}
           ]

    assert summary("verified") == [{"in_progress", "重开", :reason, false}]
    assert summary("rejected") == [{"new", "重新提交", :reason, true}]
    assert summary("cancelled") == [{"new", "恢复", :direct, true}]
  end

  test "only allowed targets are shown" do
    assert [%{to: "in_progress"}] = TaskTransitions.buttons("new", [:in_progress])
    assert TaskTransitions.buttons("new", []) == []
  end

  test "unknown combinations are skipped with a warning" do
    log =
      capture_log(fn ->
        assert [%{to: "in_progress"}] =
                 TaskTransitions.buttons("new", [:in_progress, :verified])
      end)

    assert log =~ "no button for transition new -> verified"
  end

  test "panel_help explains each reason transition" do
    for {from, to} <- [
          {"done", "in_progress"},
          {"verified", "in_progress"},
          {"new", "rejected"},
          {"rejected", "new"},
          {"in_progress", "cancelled"}
        ] do
      assert TaskTransitions.panel_help(from, to) != "", "#{from} -> #{to}"
    end
  end

  describe "self_verify_hint/2" do
    @passed %{command: "mix test", passed: true, summary: ""}
    @failed %{command: "mix test", passed: false, summary: ""}

    defp task(assignee, history),
      do: %{assignee: assignee && %{name: assignee, kind: "human"}, history: history}

    defp done(tests), do: %{from: "in_progress", to: "done", tests: tests}

    test "only for the assignee" do
      alice = %{actor: %{name: "alice"}}

      assert %{last_done_tests: @passed} =
               TaskTransitions.self_verify_hint(task("alice", [done(nil), done(@passed)]), alice)

      assert %{last_done_tests: @failed} =
               TaskTransitions.self_verify_hint(
                 task("alice", [done(@passed), done(@failed)]),
                 alice
               )

      assert %{last_done_tests: nil} =
               TaskTransitions.self_verify_hint(task("alice", [done(nil)]), alice)

      assert TaskTransitions.self_verify_hint(task("bob", [done(nil)]), alice) == nil
      assert TaskTransitions.self_verify_hint(task(nil, []), alice) == nil

      # The owner of the assigned agent is not the assignee.
      assert TaskTransitions.self_verify_hint(task("alice/feature-x", []), alice) == nil
    end
  end

  describe "TransitionErrors.message/2" do
    test "texts of each error" do
      assert TransitionErrors.message({:invalid_transition, :cancelled, :done, [:new]}, "完成") ==
               {:blocked, "任务状态已变为已撤销，无法完成"}

      assert TransitionErrors.message({:status_changed, :done}, "开始") ==
               {:blocked, "任务状态已变为待验收，无法开始"}

      assert TransitionErrors.message({:invalid_commits, "xyz"}, "完成") ==
               {{:field, :commits}, "不是有效的提交 hash：xyz"}

      assert TransitionErrors.message({:invalid_commits, ["xyz", "q"]}, "完成") ==
               {{:field, :commits}, "不是有效的提交 hash：xyz、q"}

      assert TransitionErrors.message({:invalid_tests, :not_an_object}, "完成") ==
               {{:field, :tests}, "测试结果无效"}

      assert TransitionErrors.message({:invalid_comment, :too_long}, "打回") ==
               {{:field, :comment}, "不能超过 10000 个字符"}

      assert TransitionErrors.message({:self_verify_requires_tests, "alice"}, "验收") ==
               {:top, "你是执行方，验收需要通过的测试结果"}

      assert TransitionErrors.message(:forbidden, "开始") == {:top, "没有权限执行此操作"}

      assert capture_log(fn ->
               assert TransitionErrors.message(:boom, "开始") == {:top, "操作失败，请稍后重试"}
             end) =~ ":boom"
    end

    test "an invalid reason feedback is shown under the reason" do
      {:error, changeset} = Helmsman.Feedback.normalize(%{content: String.duplicate("a", 65_537)})

      assert TransitionErrors.message(changeset, "打回") == {{:field, :comment}, "不能超过 64 KB"}

      {:error, blank} = Helmsman.Feedback.normalize(%{content: ""})
      assert TransitionErrors.message(blank, "打回") == {{:field, :comment}, "不能为空"}
    end

    test "a reason that is not an object is a program error, logged" do
      assert capture_log(fn ->
               assert TransitionErrors.message({:invalid_feedback, :not_an_object}, "打回") ==
                        {:top, "操作失败，请稍后重试"}
             end) =~ "invalid_feedback"
    end
  end

  test "reason_kind: 撤销 is a comment, the other reasons are reviews" do
    assert TaskTransitions.reason_kind("cancelled") == "comment"

    for to <- ~w(in_progress rejected new),
        do: assert(TaskTransitions.reason_kind(to) == "review")
  end
end
