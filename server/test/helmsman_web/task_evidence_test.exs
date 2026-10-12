defmodule HelmsmanWeb.TaskEvidenceTest do
  use ExUnit.Case, async: true

  alias HelmsmanWeb.TaskEvidence

  test "commits are split on blanks and commas" do
    assert {:ok, %{commits: ["ABC1234", "def5678", "0011223"]}} =
             TaskEvidence.parse(%{
               "commits" => " ABC1234 def5678,\n0011223, ",
               "result" => "none"
             })

    assert {:ok, opts} = TaskEvidence.parse(%{"commits" => "  ", "result" => "none"})
    refute Map.has_key?(opts, :commits)
  end

  test "test results" do
    assert {:ok, opts} = TaskEvidence.parse(%{"result" => "none", "command" => "mix test"})
    refute Map.has_key?(opts, :tests)

    assert {:ok, %{tests: %{command: "mix test", passed: true, summary: "42 tests"}}} =
             TaskEvidence.parse(%{
               "result" => "passed",
               "command" => " mix test ",
               "summary" => "42 tests"
             })

    assert {:ok, %{tests: %{command: "mix test", passed: false, summary: ""}}} =
             TaskEvidence.parse(%{"result" => "failed", "command" => "mix test"})
  end

  test "a test result needs a command" do
    assert TaskEvidence.parse(%{"result" => "failed", "command" => "  "}) ==
             {:error, %{command: "不能为空"}}

    assert TaskEvidence.parse(%{"result" => "passed"}) == {:error, %{command: "不能为空"}}
  end

  test "a reason panel needs a reason; the evidence comment is optional" do
    assert TaskEvidence.parse(%{"kind" => "reason", "comment" => "  "}) ==
             {:error, %{comment: "请填写原因"}}

    assert {:ok, %{comment: "登录后仍跳到首页"}} =
             TaskEvidence.parse(%{"kind" => "reason", "comment" => " 登录后仍跳到首页 "})

    assert {:ok, opts} = TaskEvidence.parse(%{"kind" => "evidence", "comment" => ""})
    refute Map.has_key?(opts, :comment)
  end
end
