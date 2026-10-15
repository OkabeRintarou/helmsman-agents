defmodule HelmsmanWeb.SpecPanelsTest do
  @moduledoc """
  Spec web-specs 请求与取消评审, 定稿与批准 and 退回、放弃、重新打开与修改 change_id
  (add-spec-workflow-ui D10, D14, tasks 3.3) on the real domain.
  """
  use HelmsmanWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Helmsman.TaskSpecsFixtures
  import HelmsmanWeb.PortalHelpers
  import HelmsmanWeb.SpecWebHelpers

  alias Helmsman.{Tasks, TaskSpecs}
  alias HelmsmanWeb.SpecErrors

  setup %{conn: conn} do
    ctx = spec_web_fixture()
    Map.put(ctx, :conn, conn)
  end

  defp open(ctx, who, query) do
    user = Map.fetch!(%{alice: ctx.alice, bob: ctx.bob}, who)
    live(log_in_user(ctx.conn, user), ctx.path <> query)
  end

  defp bob_name(ctx), do: ctx.bob_scope.actor.name
  defp dom(name), do: String.replace(name, ~r/[^A-Za-z0-9_-]/, "_")

  describe "请求与取消评审" do
    test "请人和 Agent 评审", ctx do
      submit(run_scope(ctx, ctx.fe), ctx, 0, spec_files())
      {:ok, view, _html} = open(ctx, :alice, "?panel=request")
      assert open?(view, "spec-request-panel")

      render_submit(view, "request_submit", %{
        "request" => %{"reviewers" => ["", bob_name(ctx), "keel/review"], "note" => "重点看并发"}
      })

      html = render(view)
      assert html =~ "已请 #{bob_name(ctx)} 评审"
      assert html =~ "已为 keel/review 排队评审"
      assert has_element?(view, "#spec-status", "评审中")
      assert has_element?(view, "#spec-pending-1", bob_name(ctx))
      assert has_element?(view, "#spec-pending-2", "keel/review")
    end

    test "作者不可选", ctx do
      submit(run_scope(ctx, ctx.fe), ctx, 0, spec_files())
      {:ok, view, _html} = open(ctx, :alice, "?panel=request")

      assert in_portal?(
               view,
               "spec-request-panel",
               "#spec-request-reviewer-#{dom("keel/fe")} input[disabled]"
             )

      assert in_portal?(
               view,
               "spec-request-panel",
               "#spec-request-reviewer-#{dom("keel/fe")} [data-author]",
               "作者"
             )

      refute in_portal?(view, "spec-request-panel", "#spec-request-reviewer-web-team")
    end

    test "取消请求", ctx do
      submit(ctx.alice_scope, ctx, 0, spec_files())
      {:ok, _} = TaskSpecs.request_reviews(ctx.alice_scope, ctx.ident, [bob_name(ctx)], %{})
      {:ok, view, _html} = open(ctx, :alice, "?tab=reviews")
      assert has_element?(view, "#spec-gate-reviews[data-ok=false]")

      view |> element("#spec-pending-1-cancel") |> render_click()
      assert open?(view, "spec-cancel-request")
      render_click(view, "cancel_request", %{})

      assert has_element?(view, "#spec-request-1[data-status=cancelled]", "已取消（被撤回）")
      assert has_element?(view, "#spec-gate-reviews[data-ok=true]")
      refute has_element?(view, "#spec-pending-1")
    end

    test "not while a proposal waits", ctx do
      submit(ctx.alice_scope, ctx, 0, spec_files())
      propose(ctx, 1)
      {:ok, view, _html} = open(ctx, :alice, "?panel=request")

      assert has_element?(view, "#spec-request-review[disabled]")
      assert in_portal?(view, "spec-request-panel", "#spec-request-blocked", "待批准期间不能请求评审")
      assert in_portal?(view, "spec-request-panel", "#spec-request-submit[disabled]")
    end

    test "every request text", ctx do
      _ = ctx

      skipped = %{
        target: "keel/review",
        squad: nil,
        result: :skipped,
        reason: :unauthorized,
        run_id: nil
      }

      merged = %{skipped | result: :merged, reason: nil}

      assert {:info, "已请 bob 评审"} =
               SpecErrors.request_text(%{
                 reviewer: "bob",
                 existing: false,
                 request: 1,
                 dispatch: nil
               })

      assert {:info, "keel/review 已在评审 R3，未重复请求"} =
               SpecErrors.request_text(%{
                 reviewer: "keel/review",
                 existing: true,
                 request: 3,
                 dispatch: nil
               })

      assert {:info, "已并入 keel/review 排队中的运行"} =
               SpecErrors.request_text(%{
                 reviewer: "keel/review",
                 existing: false,
                 request: 1,
                 dispatch: merged
               })

      assert {:warning, text} =
               SpecErrors.request_text(%{
                 reviewer: "keel/review",
                 existing: false,
                 request: 1,
                 dispatch: skipped
               })

      assert text == "没有启动 keel/review：你无权触发它（请求已建立）"
    end
  end

  describe "定稿与批准" do
    test "批准 Leader 的提议", ctx do
      {:ok, _} = Tasks.transition(ctx.alice_scope, ctx.ident, "in_progress")
      submit(ctx.alice_scope, ctx, 0, spec_files())
      propose(ctx, 1)
      {:ok, view, _html} = open(ctx, :alice, "?panel=finalize")

      assert in_portal?(view, "spec-finalize-panel", "#spec-finalize-panel-title", "批准 v1")

      assert in_portal?(
               view,
               "spec-finalize-panel",
               "#spec-finalize-proposal",
               "keel/lead 提议以 v1 定稿"
             )

      assert in_portal?(
               view,
               "spec-finalize-panel",
               "#spec-finalize-wake",
               "唤醒 web-team 的 leader"
             )

      assert in_portal?(view, "spec-finalize-panel", "#spec-finalize-wake input[checked]")

      render_submit(view, "finalize_submit", %{"finalize" => %{"summary" => "", "wake" => "true"}})

      assert has_element?(view, "#spec-status", "已定稿")
      assert has_element?(view, "#spec-banner-final", "已定稿于 v1")
      assert render(view) =~ "已唤醒 web-team 的 leader（keel/lead）"
    end

    test "门槛不满足", ctx do
      submit(ctx.alice_scope, ctx, 0, spec_files())
      review(ctx, 1, "fail", [%{severity: "P1", body: "x"}])

      {:ok, _} =
        TaskSpecs.add_note(run_scope(ctx, ctx.fe), ctx.ident, "R1.1", %{
          resolution: "disputed",
          body: "no"
        })

      {:ok, view, _html} = open(ctx, :alice, "?panel=finalize")

      assert in_portal?(
               view,
               "spec-finalize-panel",
               "#spec-finalize-gate-issues[data-ok=false]",
               "R1.1"
             )

      assert in_portal?(
               view,
               "spec-finalize-panel",
               "#spec-finalize-gate-issues [data-gate-link]",
               "R1.1"
             )

      assert in_portal?(view, "spec-finalize-panel", "#spec-finalize-submit[disabled]")
    end

    test "并发变化", ctx do
      submit(ctx.alice_scope, ctx, 0, spec_files())
      {:ok, view, _html} = open(ctx, :alice, "?panel=finalize")
      refute in_portal?(view, "spec-finalize-panel", "#spec-finalize-submit[disabled]")

      {:ok, _} = TaskSpecs.request_reviews(ctx.bob_scope, ctx.ident, ["keel/review"], %{})

      render_submit(view, "finalize_submit", %{
        "finalize" => %{"summary" => "", "wake" => "false"}
      })

      assert in_portal?(view, "spec-finalize-panel", "[role=alert]", "最新版本还有待完成的评审：keel/review")
      assert in_portal?(view, "spec-finalize-panel", "#spec-finalize-gate-reviews[data-ok=false]")
      assert {:ok, %{status: :in_review}} = TaskSpecs.summary(ctx.alice_scope, ctx.ident)
    end

    test "执行方是人", ctx do
      {:ok, _} = Tasks.update(ctx.alice_scope, ctx.ident, %{assignee: bob_name(ctx)})
      submit(ctx.alice_scope, ctx, 0, spec_files())
      {:ok, view, _html} = open(ctx, :alice, "?panel=finalize")

      assert in_portal?(view, "spec-finalize-panel", "#spec-finalize-panel-title", "定稿 v1")
      refute in_portal?(view, "spec-finalize-panel", "#spec-finalize-wake")
    end

    test "without 通知执行方 nobody is woken", ctx do
      submit(ctx.alice_scope, ctx, 0, spec_files())
      {:ok, view, _html} = open(ctx, :alice, "?panel=finalize")

      render_submit(view, "finalize_submit", %{
        "finalize" => %{"summary" => "ok", "wake" => "false"}
      })

      html = render(view)
      assert html =~ "已定稿于 v1"
      refute html =~ "唤醒"
    end
  end

  describe "退回、放弃、重新打开与修改 change_id" do
    test "退回提议", ctx do
      submit(ctx.alice_scope, ctx, 0, spec_files())
      propose(ctx, 1)
      {:ok, view, _html} = open(ctx, :alice, "")

      view |> element("#spec-banner-reject") |> render_click()
      assert open?(view, "spec-reason-panel")
      render_submit(view, "reason_submit", %{"reason" => %{"reason" => "", "wake" => "false"}})
      assert in_portal?(view, "spec-reason-panel", "#spec-reason-form", "必填")

      render_submit(view, "reason_submit", %{
        "reason" => %{"reason" => "缺少迁移方案", "wake" => "false"}
      })

      assert has_element?(view, "#spec-status", "草稿")
      refute has_element?(view, "#spec-banner-proposal")

      {:ok, history, _html} = open(ctx, :alice, "?tab=history")
      assert has_element?(history, "[data-action=proposal_rejected]", "退回")
      assert has_element?(history, "[data-action=proposal_rejected] [data-detail]", "缺少迁移方案")
    end

    test "重新打开已定稿的规格", ctx do
      submit(ctx.alice_scope, ctx, 0, spec_files())
      submit(ctx.alice_scope, ctx, 1, spec_files(tag: "2"))
      submit(ctx.alice_scope, ctx, 2, spec_files(tag: "3"))
      {:ok, _} = TaskSpecs.finalize(ctx.alice_scope, ctx.ident, %{version: 3, wake: false})
      {:ok, view, _html} = open(ctx, :alice, "?panel=reopen")
      refute has_element?(view, "#spec-new-version")

      render_submit(view, "reason_submit", %{"reason" => %{"reason" => "实现中发现遗漏"}})
      assert has_element?(view, "#spec-status", "草稿")
      assert has_element?(view, "#spec-version-3 [data-finalized]")
      assert has_element?(view, "#spec-new-version")
    end

    test "放弃", ctx do
      submit(ctx.alice_scope, ctx, 0, spec_files())
      {:ok, view, _html} = open(ctx, :alice, "?panel=abandon")
      assert in_portal?(view, "spec-reason-panel", "#spec-reason-abandon-note", "待完成的评审请求将作废")

      render_submit(view, "reason_submit", %{"reason" => %{"reason" => "改为别的方案"}})
      assert has_element?(view, "#spec-banner-abandoned")
      assert has_element?(view, "#spec-status", "已放弃")
    end

    test "change_id 重复", ctx do
      other = Helmsman.ProjectsFixtures.task_fixture(ctx.alice_scope, ctx.project.key)
      spec_fixture(ctx.alice_scope, other.ident, versions: 0, change_id: "add-x")
      submit(ctx.alice_scope, ctx, 0, spec_files())
      {:ok, view, _html} = open(ctx, :alice, "?panel=change-id")

      render_change(view, "change_id_change", %{"change_id" => %{"value" => "Bad!"}})
      assert in_portal?(view, "spec-change-id-panel", "#spec-change-id-form", "change_id 只能用")

      render_submit(view, "change_id_submit", %{"change_id" => %{"value" => "add-x"}})
      assert in_portal?(view, "spec-change-id-panel", "#spec-change-id-form", "这个 change_id 已被使用")

      assert portal_attr(view, "spec-change-id-panel", "#spec-change-id-value", "value") ==
               "add-x"

      assert {:ok, %{change_id: id}} = TaskSpecs.summary(ctx.alice_scope, ctx.ident)
      assert id != "add-x"

      render_submit(view, "change_id_submit", %{"change_id" => %{"value" => "add-settings"}})
      assert has_element?(view, "#spec-change-id", "add-settings")
    end
  end
end
