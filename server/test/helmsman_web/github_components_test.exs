defmodule HelmsmanWeb.GitHubComponentsTest do
  @moduledoc "add-github-ui D8 (check summary), D9 (verdicts and reason texts), D11."
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias HelmsmanWeb.GitHubComponents

  @now ~U[2026-10-13 12:00:00Z]

  defp pr(attrs \\ %{}) do
    Map.merge(
      %{
        number: 34,
        url: "https://github.com/acme/web/pull/34",
        repository: %{full_name: "acme/web"},
        state: "open",
        branch: "helmsman/BOS-12",
        base_branch: "main",
        head_sha: String.duplicate("c", 40),
        checks_state: "pending",
        checks: nil,
        merge_status: "none",
        merge_reason: nil,
        merge_note: nil,
        merged_sha: nil,
        merged_at: nil,
        waiting_since: nil,
        auto_reopen_count: 0,
        max_auto_reopens: 3,
        verified_sha: nil,
        merge_request: nil,
        can: %{reverify: false, merge_now: false, skip_independence: false, retry: false}
      },
      Map.new(attrs)
    )
  end

  defp verdict(attrs, status \\ "verified") do
    v = GitHubComponents.verdict(pr(attrs), status, @now)
    {v.tone, v.label, v.text}
  end

  describe "verdict/3 (D9 first table)" do
    test "every row, in order" do
      rows = [
        {%{state: "merged", merge_status: "merged", merged_at: ~U[2026-10-13 10:00:00Z]},
         {:review, "已合并", "已合并到 main"}},
        {%{state: "closed"}, {:danger, "已关闭", "PR 已关闭"}},
        {%{state: "closed", merge_reason: "pr_closed"},
         {:danger, "已关闭", "PR 在 GitHub 上被关闭，需要在 GitHub 上重新打开"}},
        {%{
           merge_status: "waiting",
           merge_reason: "ci_pending",
           waiting_since: ~U[2026-10-13 11:48:00Z]
         }, {:info, "等待中", "等待 CI · 已等待 12 分钟"}},
        {%{merge_status: "waiting", merge_reason: "ci_pending"}, {:info, "等待中", "等待 CI"}},
        {%{merge_status: "waiting", merge_reason: "run_active"}, {:info, "等待中", "等待运行结束后合并"}},
        {%{merge_status: "waiting", merge_reason: "required_checks"},
         {:info, "等待中", "等待分支保护要求的检查"}},
        {%{merge_status: "stale", merge_reason: "head_changed"},
         {:warning, "验收后有新提交", "验收后分支上有新提交，需要按当前提交重新验收"}},
        {%{merge_status: "failed", merge_reason: "ci_failed_limit", auto_reopen_count: 3},
         {:danger, "需要人处理", "已自动重开 3 次仍然 CI 失败，需要人处理"}},
        {%{merge_status: "failed", merge_reason: "merge_conflict_limit", auto_reopen_count: 2},
         {:danger, "需要人处理", "已自动重开 2 次仍有合并冲突，需要人处理"}},
        {%{merge_status: "none", merge_reason: "policy_manual"},
         {:muted, "手动合并", "项目设置为不自动合并：在 GitHub 上合并，或点立即合并"}}
      ]

      for {attrs, expected} <- rows do
        assert verdict(attrs) == expected, inspect(attrs)
      end
    end

    test "the merged verdict carries the merge time" do
      at = ~U[2026-10-13 10:00:00Z]
      assert %{at: ^at} = GitHubComponents.verdict(pr(state: "merged", merged_at: at), "verified")
    end

    test "tasks not verified yet: by the pull request state" do
      assert verdict(%{state: "draft"}, "in_progress") == {:muted, "草稿", "任务完成后转为可评审"}
      assert verdict(%{state: "open"}, "done") == {:muted, "等待验收", nil}
    end
  end

  describe "reason_text/2 (D9 blocked table)" do
    test "every code" do
      rows = [
        {"agent_verified", "由 Agent 验收；项目要求人验收后才自动合并"},
        {"not_independent", "验收不独立：验收人参与了这份代码（出处或触发链上），或是执行方自验收"},
        {"verified_sha_missing", "这次验收没有记下提交，可按当前提交重新验收"},
        {"verified_sha_not_pushed", "被验收的提交不是 Helmsman 运行推送到当前仓库的，可按当前提交重新验收，或在 GitHub 上合并"},
        {"push_chain_broken", "分支上有不是 Helmsman 运行推送的提交，需要在 GitHub 上合并"},
        {"ci_timeout", "CI 6 小时内没有结果；处理后点重试"},
        {"merge_rejected", "GitHub 拒绝合并（分支保护等），需要在 GitHub 上处理"},
        {"pr_closed", "PR 在 GitHub 上被关闭，需要在 GitHub 上重新打开"},
        {"repository_unavailable", "仓库不可用（安装已断开或仓库移出范围）"},
        {"branch_missing", "任务分支在 GitHub 上不存在，无法开 PR"}
      ]

      for {code, text} <- rows do
        assert verdict(%{merge_status: "blocked", merge_reason: code}) == {:danger, "已阻止", text}
      end
    end

    test "an unknown code shows GitHub's note and is marked" do
      v =
        GitHubComponents.verdict(
          pr(merge_status: "blocked", merge_reason: "new_reason", merge_note: "Something new."),
          "verified"
        )

      assert %{tone: :danger, label: "已阻止", text: "Something new.", unknown: "new_reason"} = v
      assert GitHubComponents.reason_text("new_reason", pr()) == nil
    end
  end

  describe "checks_summary/1 (D8)" do
    defp checks(attrs),
      do:
        Map.merge(
          %{head_sha: String.duplicate("c", 40), total: 6, passed: 4, pending: 0, failed: []},
          Map.new(attrs)
        )

    test "nil without checks or for another head" do
      assert GitHubComponents.checks_summary(pr(checks: nil)) == nil

      assert GitHubComponents.checks_summary(
               pr(checks: checks(head_sha: String.duplicate("d", 40)))
             ) == nil
    end

    test "counts and failed names" do
      summary =
        GitHubComponents.checks_summary(pr(checks: checks(failed: ["test (ubuntu)", "lint"])))

      assert summary == %{
               passed: 4,
               total: 6,
               pending: 0,
               failed: ["test (ubuntu)", "lint"],
               more: 0
             }
    end

    test "more than five failures: five names and the rest counted" do
      names = for i <- 1..5, do: "check #{i}"

      summary =
        GitHubComponents.checks_summary(
          pr(checks: checks(total: 10, passed: 2, pending: 1, failed: names))
        )

      assert summary.failed == names
      assert summary.more == 2
    end
  end

  describe "pr_card/1" do
    test "a waiting pull request with failed checks" do
      html =
        render_component(&GitHubComponents.pr_card/1,
          pr:
            pr(
              checks_state: "failure",
              checks: checks(failed: ["test (ubuntu)", "lint"], pending: 0),
              merge_status: "waiting",
              merge_reason: "ci_pending"
            ),
          repository: %{full_name: "acme/web", available: true},
          task_status: "verified"
        )

      assert html =~ "可评审"
      assert html =~ "#34"
      assert html =~ ~s(rel="noopener noreferrer")
      assert html =~ "4/6 通过"
      assert html =~ "test (ubuntu)"
      assert html =~ "等待 CI"
    end

    test "nothing without a repository or a pull request" do
      assert render_component(&GitHubComponents.pr_card/1, task_status: "new") == ""
    end

    test "GitHub's note is escaped text" do
      html =
        render_component(&GitHubComponents.pr_card/1,
          pr:
            pr(merge_status: "blocked", merge_reason: "merge_rejected", merge_note: "<b>No</b>"),
          task_status: "verified"
        )

      assert html =~ "&lt;b&gt;No&lt;/b&gt;"
      refute html =~ "<b>No</b>"
    end
  end

  describe "outcome_text/1 (D11)" do
    test "every outcome" do
      assert GitHubComponents.outcome_text(%{outcome: "auto_merge", base_branch: "main"}) ==
               "CI 通过后自动合并到 main"

      assert GitHubComponents.outcome_text(%{outcome: "not_independent"}) =~ "不会自动合并"
      assert GitHubComponents.outcome_text(%{outcome: "policy_manual"}) =~ "不自动合并"
      assert GitHubComponents.outcome_text(%{outcome: "agent_verified"}) =~ "人验收"
      assert GitHubComponents.outcome_text(%{outcome: "repository_unavailable"}) =~ "仓库不可用"
    end
  end
end
