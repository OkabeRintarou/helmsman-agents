defmodule HelmsmanWeb.SpecReviewFormTest do
  @moduledoc """
  Spec web-specs 写评审 and 回复、撤回与裁定问题 (add-spec-workflow-ui D9, tasks 3.2) on the
  real domain, plus `HelmsmanWeb.SpecReviewForm`'s checks.
  """
  use HelmsmanWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Helmsman.TaskSpecsFixtures
  import HelmsmanWeb.PortalHelpers
  import HelmsmanWeb.SpecWebHelpers

  alias Helmsman.{Squads, TaskSpecs}
  alias HelmsmanWeb.SpecReviewForm

  @panel "spec-review-panel"
  @note "spec-note-panel"

  setup %{conn: conn} do
    ctx = spec_web_fixture()
    Map.put(ctx, :conn, conn)
  end

  defp open(ctx, who, query) do
    user = Map.fetch!(%{alice: ctx.alice, bob: ctx.bob}, who)
    live(log_in_user(ctx.conn, user), ctx.path <> query)
  end

  defp long_spec(tag) do
    filler = Enum.map_join(1..20, "\n", &"The system MUST keep line #{&1}. #{tag}")

    Map.put(
      spec_files(tag: tag),
      "specs/settings/spec.md",
      "## ADDED Requirements\n\n### Requirement: Save\n#{filler}\n\n#### Scenario: Saved\n- **WHEN** a\n- **THEN** b\n"
    )
  end

  defp bob_name(ctx), do: ctx.bob_scope.actor.name

  defp fill_issue(view, k, fields) do
    render_change(view, "rev_change", %{"review" => %{"issues" => %{to_string(k) => fields}}})
  end

  describe "写评审" do
    test "提交不通过的评审", ctx do
      submit(ctx.alice_scope, ctx, 0, long_spec("v1"))
      submit(ctx.alice_scope, ctx, 1, long_spec("v2"))
      {:ok, _} = TaskSpecs.request_reviews(ctx.alice_scope, ctx.ident, [bob_name(ctx)], %{})

      {:ok, view, _html} = open(ctx, :bob, "?panel=review")
      assert open?(view, @panel)
      assert in_portal?(view, @panel, "#spec-review-panel-title", "评审 v2")

      render_change(view, "rev_change", %{
        "review" => %{"verdict" => "fail", "summary" => "需要补场景"}
      })

      render_click(view, "rev_add_issue", %{})
      render_click(view, "rev_add_issue", %{})

      fill_issue(view, 0, %{
        "severity" => "P1",
        "file" => "specs/settings/spec.md",
        "line" => "12",
        "body" => "缺少保存失败的场景"
      })

      fill_issue(view, 1, %{"severity" => "P3", "body" => "措辞"})
      render_submit(view, "rev_submit", %{})

      assert render(view) =~ "已提交 R1"
      refute open?(view, @panel)
      assert has_element?(view, "#review-R1 [data-verdict=fail]")
      assert has_element?(view, "#issue-R1-1 [data-severity=P1]")
      assert has_element?(view, "#issue-R1-1 [data-resolution=open]", "待回复")
      assert has_element?(view, "#issue-R1-2 [data-severity=P3]")
      assert has_element?(view, "#spec-request-1[data-status=submitted]", "已提交 R1")
    end

    test "评审时出了新版本", ctx do
      submit(ctx.alice_scope, ctx, 0, long_spec("v1"))
      submit(ctx.alice_scope, ctx, 1, long_spec("v2"))
      {:ok, view, _html} = open(ctx, :bob, "?panel=review")

      render_change(view, "rev_change", %{
        "review" => %{"verdict" => "comment", "summary" => "看过了"}
      })

      render_click(view, "rev_add_issue", %{})

      fill_issue(view, 0, %{
        "severity" => "P2",
        "file" => "specs/settings/spec.md",
        "line" => "24",
        "body" => "x"
      })

      submit(ctx.alice_scope, ctx, 2, %{
        "specs/settings/spec.md" => spec_files(tag: "v3")["specs/settings/spec.md"]
      })

      render_submit(view, "rev_submit", %{})

      assert in_portal?(view, @panel, "#spec-review-stale", "已有 v3，评审只能针对最新版本")

      assert portal_attr(view, @panel, "#spec-review-summary", "value") == "看过了" or
               portal_text(view, @panel, "#spec-review-summary") =~ "看过了"

      render_click(view, "rev_retarget", %{})
      assert in_portal?(view, @panel, "#spec-review-panel-title", "评审 v3")
      # v3's spec.md is shorter: line 24 is past its end.
      assert in_portal?(view, @panel, "#spec-review-issue-0", "行号在 1–")
    end

    test "唤醒 leader", ctx do
      submit(ctx.alice_scope, ctx, 0, long_spec("v1"))
      lead = run_scope(ctx, ctx.lead, squad: true)

      {:ok, %{result: :requested}} =
        Squads.delegate(lead, ctx.ident, bob_name(ctx), "看并发", "review")

      {:ok, view, _html} = open(ctx, :bob, "?panel=review")
      render_change(view, "rev_change", %{"review" => %{"verdict" => "pass"}})
      render_submit(view, "rev_submit", %{})

      html = render(view)
      assert html =~ "已提交 R1"
      assert html =~ "web-team 的 leader（keel/lead）"
    end

    test "the author of the latest version may not review it", ctx do
      submit(ctx.alice_scope, ctx, 0, long_spec("v1"))
      {:ok, view, _html} = open(ctx, :alice, "?panel=review")

      assert in_portal?(view, @panel, "#spec-review-own", "你写了 v1，不能评审它")
      assert in_portal?(view, @panel, "#spec-review-submit[disabled]")
    end

    test "checks in place", ctx do
      submit(ctx.alice_scope, ctx, 0, long_spec("v1"))
      {:ok, view, _html} = open(ctx, :bob, "?panel=review")

      render_submit(view, "rev_submit", %{})
      assert in_portal?(view, @panel, "[role=alert]", "选择结论")

      render_change(view, "rev_change", %{"review" => %{"verdict" => "fail"}})
      render_click(view, "rev_add_issue", %{})
      fill_issue(view, 0, %{"body" => String.duplicate("a", 8193)})
      assert in_portal?(view, @panel, "#spec-review-issue-0", "不能超过 8 KB")

      render_submit(view, "rev_submit", %{})
      assert {:ok, %{reviews: []}} = TaskSpecs.reviews(ctx.alice_scope, ctx.ident)
    end

    test "invalid_issues from the domain mark the issue" do
      form = SpecReviewForm.new(2, %{"proposal.md" => 5})
      form = %{form | issues: [%{severity: "P1"}, %{severity: "P2"}]}

      form =
        SpecReviewForm.put_error(
          form,
          {:spec, :invalid_issues, [%{index: 2, message: "line is past the end"}]}
        )

      assert form.errors == %{{1, :issue} => "line is past the end"}
      assert form.error =~ "#2 line is past the end"
    end

    test "moving and removing issues" do
      form = SpecReviewForm.new(1, %{"proposal.md" => 5})
      form = form |> SpecReviewForm.add_issue() |> SpecReviewForm.add_issue()
      form = %{form | issues: [%{hd(form.issues) | body: "a"}, %{hd(form.issues) | body: "b"}]}

      assert form |> SpecReviewForm.move(1, "up") |> Map.get(:issues) |> Enum.map(& &1.body) == [
               "b",
               "a"
             ]

      assert form |> SpecReviewForm.move(0, "up") |> Map.get(:issues) |> Enum.map(& &1.body) == [
               "a",
               "b"
             ]

      assert form |> SpecReviewForm.remove_issue(0) |> Map.get(:issues) |> Enum.map(& &1.body) ==
               ["b"]
    end
  end

  describe "回复、撤回与裁定问题" do
    setup ctx do
      submit(ctx.alice_scope, ctx, 0, long_spec("v1"))

      review(ctx, 1, "fail", [
        %{severity: "P1", body: "保存失败"},
        %{severity: "P2", body: "措辞"},
        %{severity: "P2", body: "范围"}
      ])

      {:ok, _} =
        TaskSpecs.add_note(run_scope(ctx, ctx.fe), ctx.ident, "R1.1", %{
          resolution: "disputed",
          body: "通用错误页即可"
        })

      :ok
    end

    test "人裁定分歧", ctx do
      {:ok, view, _html} = open(ctx, :bob, "?tab=reviews")
      view |> element("#issue-r1-1-rule") |> render_click()
      assert open?(view, @note)
      assert in_portal?(view, @note, "#spec-note-quote", "保存失败")
      assert in_portal?(view, @note, "#spec-note-kind-upheld[checked]")

      render_submit(view, "note_submit", %{
        "note" => %{"kind" => "dismissed", "body" => "由通用错误页处理即可"}
      })

      refute open?(view, @note)
      assert has_element?(view, "#issue-R1-1 [data-resolution=dismissed]", "驳回")
      assert has_element?(view, "#issue-R1-1 [data-note='2']", bob_name(ctx))
      assert has_element?(view, "#issue-R1-1 [data-note='2']", "由通用错误页处理即可")
    end

    test "有异议没写理由", ctx do
      {:ok, view, _html} = open(ctx, :bob, "?tab=reviews&panel=note&issue=R1.2&kind=reply")
      render_submit(view, "note_submit", %{"note" => %{"kind" => "disputed", "body" => ""}})

      assert in_portal?(view, @note, "#spec-note-form", "必填")

      {:ok, %{reviews: [%{issues: [_, issue, _]}]}} =
        TaskSpecs.reviews(ctx.alice_scope, ctx.ident)

      assert issue.notes == []
    end

    test "并发后已解决", ctx do
      {:ok, view, _html} = open(ctx, :bob, "?tab=reviews&panel=note&issue=R1.2&kind=reply")
      assert in_portal?(view, @note, "#spec-note-kind-accepted[checked]")

      {:ok, _} =
        TaskSpecs.add_note(run_scope(ctx, ctx.review), ctx.ident, "R1.2", %{
          resolution: "withdrawn"
        })

      render_submit(view, "note_submit", %{
        "note" => %{"kind" => "accepted", "body" => "会在 v2 修改"}
      })

      assert in_portal?(view, @note, "[role=alert]", "R1.2 已是已撤回，可以追加评论")
      assert in_portal?(view, @note, "#spec-note-kind-comment[checked]")
      assert portal_text(view, @note, "#spec-note-body") =~ "会在 v2 修改"
    end

    test "accepting with the version it is fixed in", ctx do
      {:ok, view, _html} = open(ctx, :bob, "?tab=reviews&panel=note&issue=R1.3&kind=reply")
      render_change(view, "note_change", %{"note" => %{"kind" => "accepted"}})
      assert in_portal?(view, @note, "#spec-note-fixed-in")

      render_submit(view, "note_submit", %{
        "note" => %{"kind" => "accepted", "body" => "", "fixed_in" => "1"}
      })

      assert has_element?(view, "#issue-R1-3 [data-resolution=accepted]", "在 v1 修改")
    end

    test "a resolved issue only takes comments", ctx do
      {:ok, _} =
        TaskSpecs.add_note(ctx.alice_scope, ctx.ident, "R1.1", %{resolution: "upheld", body: "x"})

      {:ok, view, _html} = open(ctx, :bob, "?tab=reviews")

      assert has_element?(view, "#issue-r1-1-comment")
      refute has_element?(view, "#issue-r1-1-reply")
      refute has_element?(view, "#issue-r1-1-rule")
    end
  end
end
