defmodule HelmsmanWeb.SpecRenderingTest do
  @moduledoc """
  add-spec-workflow-ui tasks 1.1, 2.3 (texts) and 5.2: `HelmsmanWeb.SpecErrors` for every
  reason (table driven), `HelmsmanWeb.SpecComponents` rendering (diff, source view,
  labels, audit texts) and the run trigger labels of web-runs 规格相关的运行.
  """
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias HelmsmanWeb.{RunComponents, SpecComponents, SpecErrors}

  describe "SpecErrors.message/1" do
    cases = [
      {{:spec, :stale_version, 3}, "最新已是 v3"},
      {{:spec, :closed, :finalized}, "规格已定稿"},
      {{:spec, :closed, :abandoned}, "规格已放弃"},
      {{:spec, :not_closed, :draft}, "不需要重新打开"},
      {{:spec, :no_changes}, "没有可提交的修改"},
      {{:spec, :no_version}, "规格还没有版本"},
      {{:spec, :no_proposal}, "没有待批准的提议"},
      {{:spec, :pending_approval}, "规格待批准，不能请求评审"},
      {{:spec, :not_found, "BOS-1"}, "这个任务还没有规格"},
      {{:spec, :version_not_found, 9}, "没有 v9"},
      {{:spec, :invalid, [%{file: "tasks.md", line: nil, rule: "tasks_no_items", message: "m"}]},
       "校验未通过：tasks.md tasks.md 没有勾选项（m）"},
      {{:spec, :unresolved_issues, ["R2.1", "R2.3"]}, "还有未解决的 P1 / P2 问题：R2.1、R2.3"},
      {{:spec, :reviews_pending, ["bob"]}, "最新版本还有待完成的评审：bob"},
      {{:spec, :own_version, "keel/fe"}, "keel/fe 写了这个版本，不能评审它"},
      {{:spec, :issue_resolved, "R2.1", :upheld}, "R2.1 已是维持，可以追加评论"},
      {{:spec, :issue_not_found, "R9.9"}, "没有问题 R9.9"},
      {{:spec, :not_coordinator, %{}}, "只有协调者"},
      {{:spec, :invalid_reviewer, "web-team"}, "web-team 不能评审规格"},
      {{:spec, :review_pending, %{reviewer: "keel/review", request: 3, requested_by: "alice"}},
       "keel/review 已在评审 R3"},
      {{:spec, :invalid_files, [%{path: "notes.md", message: "not allowed"}]},
       "文件不合法：notes.md not allowed"},
      {{:spec, :invalid_issues, [%{index: 2, message: "bad"}]}, "问题不合法：#2 bad"},
      {{:spec, :invalid_params, %{field: :note, message: "too long"}}, "参数 note 不合法：too long"},
      {{:spec, :invalid_archive, "x"}, "压缩包不合法"},
      {:forbidden, "你没有权限执行这个操作"},
      {:not_found, "任务不存在"},
      {:busy, "有并发修改，请重试"},
      {:unavailable, "规格功能暂不可用"}
    ]

    for {reason, text} <- cases do
      test "#{inspect(reason)}" do
        assert SpecErrors.message(unquote(Macro.escape(reason))) =~ unquote(text)
      end
    end

    test "a change_id changeset" do
      taken =
        {%{}, %{change_id: :string}}
        |> Ecto.Changeset.cast(%{}, [])
        |> Ecto.Changeset.add_error(:change_id, "has already been taken")

      assert SpecErrors.message(taken) == "这个 change_id 已被使用"
    end

    test "an unknown reason shows as given" do
      assert SpecErrors.message({:spec, :mystery}) == "{:spec, :mystery}"
    end

    test "rule names, unknown rules as given" do
      assert SpecErrors.rule_label("requirement_no_normative") == "需求正文没有 SHALL / MUST"
      assert SpecErrors.rule_label("new_rule") == "new_rule"
    end
  end

  describe "wake texts" do
    test "a squad's leader, an agent, skipped, none" do
      leader = %{target: "keel/lead", squad: "web-team", result: :queued, reason: nil, run_id: 1}
      assert SpecErrors.wake_text(leader) == {:info, "已唤醒 web-team 的 leader（keel/lead）"}

      assert SpecErrors.wake_text(%{leader | squad: nil, target: "keel/dev", result: :deferred}) ==
               {:info, "已唤醒 keel/dev"}

      assert {:warning, "没有唤醒 keel/dev：你无权触发它"} =
               SpecErrors.wake_text(%{
                 leader
                 | squad: nil,
                   target: "keel/dev",
                   result: :skipped,
                   reason: :unauthorized
               })

      assert SpecErrors.wake_text(nil) == nil
    end
  end

  describe "SpecComponents" do
    test "the diff: modified, added, removed, replaced, unchanged, truncated" do
      result = %{
        truncated: true,
        files: [
          %{
            path: "proposal.md",
            change: :modified,
            hunks: [
              %{
                old_start: 1,
                old_lines: 2,
                new_start: 1,
                new_lines: 2,
                lines: [{:eq, "a"}, {:del, "b"}, {:ins, "c"}]
              }
            ]
          },
          %{
            path: "specs/a/spec.md",
            change: :added,
            hunks: [
              %{old_start: 0, old_lines: 0, new_start: 1, new_lines: 1, lines: [{:ins, "x"}]}
            ]
          },
          %{
            path: "design.md",
            change: :removed,
            hunks: [
              %{old_start: 1, old_lines: 1, new_start: 0, new_lines: 0, lines: [{:del, "y"}]}
            ]
          },
          %{path: "big.md", change: :replaced, hunks: [], old_lines: 9000, new_lines: 9100},
          %{path: "tasks.md", change: :unchanged, hunks: []}
        ]
      }

      html = render_component(&SpecComponents.diff/1, result: result)
      tree = LazyHTML.from_fragment(html)
      q = &(tree |> LazyHTML.query(&1) |> LazyHTML.text())

      assert q.("#spec-diff-summary") =~ "修改 2 · 新增 1 · 删除 1 · 不变 1"
      assert q.("#spec-diff-truncated") =~ "结果过大已截断"
      assert q.("[data-path='proposal.md'] [data-op=del]") =~ "b"
      assert q.("[data-path='proposal.md'] [data-op=ins]") =~ "c"
      assert q.("[data-path='big.md'] [data-replaced]") =~ "差异计算超时，按整体替换显示（旧 9000 行 → 新 9100 行）"
      assert q.("#spec-diff-unchanged") =~ "tasks.md"
    end

    test "the source view: line ids, target, markers" do
      issue = %{ref: "R1.1", severity: :P1, resolution: :open, body: "x"}

      html =
        render_component(&SpecComponents.source_view/1,
          content: "a\nb\nc",
          line: 2,
          markers: %{2 => [issue]},
          add_path: &"/add/#{&1}",
          issue_path: &"/issue/#{&1}"
        )

      assert html =~ ~s(id="L3")

      assert html =~
               ~s(id="L2" data-line-number="2" class="hm-spec-line group flex min-w-fit hm-spec-line-target")

      assert html =~ ~s(data-marker="R1.1")
      assert html =~ ~s(href="/add/3")
    end

    test "request states" do
      assert SpecComponents.request_label(%{status: :lapsed}) == "已过期（评审运行结束时没有提交）"
      assert SpecComponents.request_label(%{status: :submitted, review: 2}) == "已提交 R2"

      assert SpecComponents.request_label(%{status: :cancelled, close_reason: :superseded}) =~
               "被新版本取代"

      assert SpecComponents.request_label(%{status: :cancelled, close_reason: :withdrawn}) =~
               "被撤回"

      assert SpecComponents.request_label(%{status: :cancelled, close_reason: :abandoned}) =~
               "规格已放弃"
    end

    test "every audit action has a text" do
      cases = [
        {"created", nil, %{"change_id" => "add-x"}, "建立规格（add-x）"},
        {"change_id_changed", nil, %{"to" => "add-y"}, "change_id 改为 add-y"},
        {"version_submitted", 2, %{}, "提交 v2"},
        {"review_requested", 2, %{"reviewer" => "bob"}, "请 bob 评审 v2"},
        {"review_request_closed", nil, %{"request" => 1, "status" => "lapsed"}, "评审请求 #1 结束（过期）"},
        {"review_submitted", 2, %{"review" => 1}, "提交评审 R1（v2）"},
        {"finalize_proposed", 2, %{}, "提议以 v2 定稿"},
        {"proposal_withdrawn", 2, %{}, "撤回 v2 的定稿提议"},
        {"approved", 2, %{}, "批准 v2"},
        {"finalized", 2, %{}, "定稿于 v2"},
        {"proposal_rejected", 2, %{}, "退回 v2 的定稿提议"},
        {"abandoned", nil, %{}, "放弃"},
        {"reopened", nil, %{}, "重新打开"}
      ]

      for {action, v, data, text} <- cases,
          do: assert(SpecComponents.event_text(%{action: action, version: v, data: data}) == text)
    end
  end

  describe "规格相关的运行" do
    @by %{name: "keel/lead", kind: "agent"}

    test "委派评审, 批准后唤醒, 退回" do
      review = %{
        kind: "delegated",
        by: @by,
        spec_role: "review",
        spec_version: 2,
        spec_request: 1
      }

      assert RunComponents.trigger_label(review) == "keel/lead 委派：评审规格 v2"

      assert RunComponents.trigger_path(review, "acme", "BOS-12") ==
               "/w/acme/t/BOS-12/spec?tab=reviews"

      alice = %{name: "alice", kind: "human"}
      approved = %{kind: "spec_decided", by: alice, decision: "approved", version: 3}
      assert RunComponents.trigger_label(approved) == "alice 批准了规格 v3"
      assert RunComponents.trigger_path(approved, "acme", "BOS-12") == "/w/acme/t/BOS-12/spec"

      rejected = %{
        kind: "spec_decided",
        by: alice,
        decision: "rejected",
        version: 3,
        reason: "缺少迁移方案"
      }

      assert RunComponents.trigger_label(rejected) == "alice 退回了规格"
      assert RunComponents.trigger_detail(rejected) == "缺少迁移方案"
    end

    test "the other spec triggers" do
      assert RunComponents.trigger_label(%{kind: "delegated", by: @by, spec_role: "draft"}) ==
               "keel/lead 委派：起草规格"

      assert RunComponents.trigger_label(%{kind: "delegated", by: @by, spec_role: "revise"}) ==
               "keel/lead 委派：修订规格"

      assert RunComponents.trigger_label(%{
               kind: "spec_review",
               by: %{name: "alice"},
               spec_version: 2
             }) == "alice 请求评审规格 v2"

      reviewed = %{
        kind: "spec_reviewed",
        by: %{name: "bob"},
        version: 2,
        verdict: "fail",
        counts: %{"P1" => 1, "P2" => 1, "P3" => 0}
      }

      assert RunComponents.trigger_label(reviewed) == "bob 评审了规格 v2：不通过"
      assert RunComponents.trigger_detail(reviewed) == "P1 1 · P2 1 · P3 0"

      assert RunComponents.trigger_label(%{
               kind: "spec_decided",
               by: %{name: "alice"},
               decision: "finalized",
               version: 3
             }) == "alice 定稿于 v3"
    end

    test "without their fields the generic label stays" do
      assert RunComponents.trigger_label(%{kind: "delegated", by: @by}) == "keel/lead 委派"

      assert RunComponents.trigger_label(%{kind: "spec_review", by: %{name: "alice"}}) ==
               "alice 请求评审规格"

      assert RunComponents.trigger_label(%{kind: "spec_decided", by: %{name: "alice"}}) ==
               "alice 处理了规格"

      assert RunComponents.trigger_path(%{kind: "delegated", by: @by}, "acme", "BOS-12") == nil
      assert RunComponents.trigger_path(%{kind: "spec_review"}, "acme", nil) == nil
    end
  end
end
