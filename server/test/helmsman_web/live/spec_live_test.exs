defmodule HelmsmanWeb.SpecLiveTest do
  @moduledoc """
  Spec web-specs 规格页, 规格文件与校验结果, 规格版本对比, 规格评审与讨论的显示,
  规格页的权限 and 规格的实时刷新 (add-spec-workflow-ui tasks 1.2, 2.1–2.3, 4.3, 5.1),
  against the real `Helmsman.TaskSpecs`.
  """
  use HelmsmanWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Helmsman.AccountsFixtures
  import Helmsman.ProjectsFixtures
  import Helmsman.TaskSpecsFixtures
  import Helmsman.WorkspacesFixtures
  import HelmsmanWeb.LiveHelpers
  import HelmsmanWeb.PortalHelpers
  import HelmsmanWeb.SpecWebHelpers

  alias Helmsman.TaskSpecs
  alias HelmsmanWeb.SpecLive.Show

  setup %{conn: conn} do
    ctx = spec_web_fixture()
    Map.put(ctx, :conn, conn)
  end

  defp open(ctx, who, query \\ "") do
    user = Map.fetch!(%{alice: ctx.alice, bob: ctx.bob, vic: ctx.vic}, who)
    live(log_in_user(ctx.conn, user), ctx.path <> query)
  end

  # A valid spec whose spec.md has `n` lines (filler in the requirement's body).
  defp long_files(n, tag) do
    filler = Enum.map_join(1..max(n - 9, 1), "\n", &"The system MUST keep line #{&1}. #{tag}")

    spec_files(tag: tag)
    |> Map.put(
      "specs/settings/spec.md",
      "## ADDED Requirements\n\n### Requirement: Save\n" <>
        filler <> "\n\n#### Scenario: Saved\n- **WHEN** a user saves\n- **THEN** it is stored\n"
    )
  end

  defp versions(ctx, n, lines \\ 30) do
    for v <- 1..n, do: submit(ctx.alice_scope, ctx, v - 1, long_files(lines, "v#{v}"))
    :ok
  end

  describe "规格页" do
    test "opening a version's source line directly", ctx do
      versions(ctx, 3)
      {:ok, view, _html} = open(ctx, :alice, "?v=2&file=specs/settings/spec.md&line=12")

      assert has_element?(view, "#spec-file-path", "specs/settings/spec.md")
      assert has_element?(view, "#spec-source #L12.hm-spec-line-target")
      assert has_element?(view, "#spec-source[data-line='12']")
      assert has_element?(view, "#spec-banner-old", "你在看 v2，最新是 v3")
      assert has_element?(view, "#spec-version-2.bg-hover")
    end

    test "invalid params fall back to the defaults", ctx do
      versions(ctx, 2)
      {:ok, view, _html} = open(ctx, :alice, "?tab=nope&v=99&file=x.md&panel=bogus")

      assert has_element?(view, "#spec-file-path", "proposal.md")
      assert has_element?(view, "#spec-rendered")
      refute has_element?(view, "#spec-banner-old")
    end

    test "another workspace's task is 404", ctx do
      other = user_fixture()
      ws = workspace_fixture(other, %{name: "Ops"})
      scope = workspace_scope_fixture(other, ws)
      project = project_fixture(scope, %{key: "OPS"})
      task = task_fixture(scope, project.key)

      assert_raise HelmsmanWeb.NotFoundError, fn ->
        live(log_in_user(ctx.conn, ctx.alice), "/w/#{ctx.slug}/t/#{task.ident}/spec")
      end
    end

    test "a version once finalized keeps its mark", ctx do
      versions(ctx, 2)
      {:ok, _} = TaskSpecs.finalize(ctx.alice_scope, ctx.ident, %{version: 2, wake: false})
      {:ok, _} = TaskSpecs.reopen(ctx.alice_scope, ctx.ident, %{reason: "实现中发现遗漏"})
      submit(ctx.alice_scope, ctx, 2, long_files(30, "v3"))
      submit(ctx.alice_scope, ctx, 3, long_files(30, "v4"))

      {:ok, view, _html} = open(ctx, :alice)
      alice = ctx.alice_scope.actor.name

      assert has_element?(view, "#spec-version-2 [data-finalized]", "定稿 · #{alice}")
      refute has_element?(view, "#spec-version-4 [data-finalized]")
      assert has_element?(view, "#spec-status", "草稿")
      refute has_element?(view, "#spec-banner-final")
    end

    test "no spec, an empty spec", ctx do
      {:ok, view, _html} = open(ctx, :bob)
      assert has_element?(view, "#spec-empty", "还没有规格")
      assert has_element?(view, "#spec-empty-start")
      assert has_element?(view, "#spec-empty-draft")

      view |> element("#spec-empty-start") |> render_click()
      assert has_element?(view, "#spec-status", "草稿")
      assert has_element?(view, "#spec-change-id", String.downcase(ctx.ident))
      refute has_element?(view, "#spec-empty-start")
      assert has_element?(view, "#spec-empty-draft")

      {:ok, viewer, _html} = open(ctx, :vic)
      assert has_element?(viewer, "#spec-empty")
      refute has_element?(viewer, "#spec-empty-draft")
    end

    test "the proposal banner and the gate", ctx do
      versions(ctx, 1)
      propose(ctx, 1, "所有问题已解决")
      {:ok, view, _html} = open(ctx, :alice)

      assert has_element?(view, "#spec-banner-proposal", "keel/lead 提议以 v1 定稿")
      assert has_element?(view, "#spec-banner-proposal", "所有问题已解决")
      assert has_element?(view, "#spec-banner-approve")
      assert has_element?(view, "#spec-gate-valid[data-ok=true]")
      assert has_element?(view, "#spec-mode", "需要人批准")
    end
  end

  describe "规格文件与校验结果" do
    test "a validation error jumps to its line", ctx do
      submit(ctx.alice_scope, ctx, 0, spec_files(invalid: true))
      {:ok, view, _html} = open(ctx, :alice)

      [error] =
        TaskSpecs.get(ctx.alice_scope, ctx.ident)
        |> elem(1)
        |> get_in([:version, :validation, :errors])

      assert has_element?(view, "#spec-validation", "需求没有场景")
      assert has_element?(view, "#spec-file-specs-settings-spec-md [data-invalid]")

      view |> element("#spec-validation-0") |> render_click()

      assert_patch(
        view,
        ctx.path <> "?file=#{URI.encode_www_form(error.file)}&line=#{error.line}&view=source"
      )

      assert has_element?(view, "#L#{error.line}.hm-spec-line-target")
    end

    test "issue markers belong to their version", ctx do
      versions(ctx, 2)

      review(ctx, 2, "fail", [
        %{severity: "P1", file: "specs/settings/spec.md", line: 12, body: "缺少保存失败的场景"}
      ])

      submit(ctx.alice_scope, ctx, 2, long_files(30, "v3"))

      {:ok, view, _html} = open(ctx, :alice, "?v=2&file=specs/settings/spec.md&view=source")
      assert has_element?(view, "#L12-R1\\.1[data-severity=P1][data-resolved=false]")
      assert has_element?(view, "#spec-file-specs-settings-spec-md [data-unresolved]", "1")

      view |> element("#L12-R1\\.1") |> render_click()
      assert_patch(view)
      assert has_element?(view, "#issue-R1-1.ring-2")

      {:ok, v3, _html} = open(ctx, :alice, "?v=3&file=specs/settings/spec.md&view=source")
      refute has_element?(v3, "[data-marker]")
    end

    test "在此行提问题 on the latest version", ctx do
      versions(ctx, 1)
      {:ok, view, _html} = open(ctx, :bob, "?file=specs/settings/spec.md&view=source")

      view |> element("#L20-add") |> render_click()
      assert open?(view, "spec-review-panel")

      assert in_portal?(
               view,
               "spec-review-panel",
               "#spec-review-issue-0-file option[selected][value='specs/settings/spec.md']"
             )

      assert portal_attr(view, "spec-review-panel", "#spec-review-issue-0-line", "value") == "20"
    end

    test "a resolved issue's marker without opening the reviews tab", ctx do
      versions(ctx, 2)

      review(ctx, 2, "fail", [
        %{severity: "P1", file: "specs/settings/spec.md", line: 12, body: "x"}
      ])

      {:ok, _} =
        TaskSpecs.add_note(ctx.alice_scope, ctx.ident, "R1.1", %{
          resolution: "upheld",
          body: "需要就地提示"
        })

      {:ok, view, _html} = open(ctx, :alice, "?v=2&file=specs/settings/spec.md&line=12")
      assert has_element?(view, "#L12-R1\\.1[data-resolved=true]")
      refute has_element?(view, "#spec-file-specs-settings-spec-md [data-unresolved]")
    end

    test "markers and counts follow the issue's state; switching files does not re-read", ctx do
      versions(ctx, 1)

      review(ctx, 1, "comment", [
        %{severity: "P2", file: "specs/settings/spec.md", line: 3, body: "x"}
      ])

      {:ok, view, _html} = open(ctx, :alice, "?file=specs/settings/spec.md&view=source")

      assert has_element?(view, "#spec-file-specs-settings-spec-md [data-unresolved]", "1")
      cache = :sys.get_state(view.pid).socket.assigns.marker_cache

      view |> element("#spec-file-proposal-md") |> render_click()
      assert :sys.get_state(view.pid).socket.assigns.marker_cache == cache

      {:ok, _} =
        TaskSpecs.add_note(run_scope(ctx, ctx.fe), ctx.ident, "R1.1", %{resolution: "accepted"})

      eventually(fn ->
        !has_element?(view, "#spec-file-specs-settings-spec-md [data-unresolved]")
      end)

      view |> element("#spec-file-specs-settings-spec-md") |> render_click()
      render_patch(view, ctx.path <> "?file=specs/settings/spec.md&view=source")
      assert has_element?(view, "#L3-R1\\.1[data-resolved=true]")
    end

    test "a file of more than 5000 lines is shown in parts", ctx do
      files = Map.put(spec_files(), "design.md", Enum.map_join(1..6000, "\n", &"line #{&1}"))
      submit(ctx.alice_scope, ctx, 0, files)
      {:ok, view, _html} = open(ctx, :alice, "?file=design.md&view=source")

      assert has_element?(view, "#L2000")
      refute has_element?(view, "#L2001")
      view |> element("#spec-source-more") |> render_click()
      assert has_element?(view, "#L4000")

      # Another file starts over.
      render_patch(view, ctx.path <> "?file=proposal.md&view=source")
      render_patch(view, ctx.path <> "?file=design.md&view=source")
      refute has_element?(view, "#L2001")
    end

    test "a line past the first part of a big file is shown and targeted", ctx do
      files = Map.put(spec_files(), "design.md", Enum.map_join(1..6000, "\n", &"line #{&1}"))
      submit(ctx.alice_scope, ctx, 0, files)
      review(ctx, 1, "comment", [%{severity: "P2", file: "design.md", line: 4500, body: "x"}])

      {:ok, view, _html} = open(ctx, :alice, "?file=design.md&line=4500")
      assert has_element?(view, "#L4500.hm-spec-line-target")
      assert has_element?(view, "#spec-source[data-line='4500']")
      # Parts of 2000 lines: 4500 needs three, i.e. the whole 6000.
      assert has_element?(view, "#L6000")
      refute has_element?(view, "#spec-source-more")

      # The same from the issue's location in the reviews tab.
      {:ok, reviews, _html} = open(ctx, :alice, "?tab=reviews")
      reviews |> element("#issue-R1-1 [data-location]") |> render_click()
      assert has_element?(reviews, "#L4500.hm-spec-line-target")
    end

    test "the rendered view uses the Markdown renderer", ctx do
      files =
        Map.put(spec_files(), "design.md", "## Context\n\n```mermaid\ngraph TD; A-->B\n```\n")

      submit(ctx.alice_scope, ctx, 0, files)
      {:ok, view, _html} = open(ctx, :alice, "?file=design.md")

      assert has_element?(view, "#spec-rendered h2", "Context")
      assert has_element?(view, "#spec-rendered pre.hm-mermaid[data-mermaid]")
    end
  end

  describe "规格版本对比" do
    test "comparing two versions", ctx do
      base = Map.put(spec_files(), "design.md", "## Context\n\nold\n")
      submit(ctx.alice_scope, ctx, 0, base)
      submit(ctx.alice_scope, ctx, 1, %{"tasks.md" => "## 1. Settings\n\n- [ ] 1.1 Build it\n"})

      proposal = String.replace(base["proposal.md"], "Settings get lost.", "Settings vanish.")

      submit(
        ctx.alice_scope,
        ctx,
        2,
        %{
          "proposal.md" => proposal,
          "specs/api/spec.md" => spec_files()["specs/settings/spec.md"]
        },
        %{remove: ["design.md"]}
      )

      {:ok, view, _html} = open(ctx, :alice, "?tab=diff&from=1&to=3")
      render_async(view)

      assert has_element?(view, "#spec-diff-summary", "修改 2 · 新增 1 · 删除 1")

      assert has_element?(
               view,
               "[data-path='proposal.md'][data-change=modified] [data-op=del]",
               "Settings get lost."
             )

      assert has_element?(
               view,
               "[data-path='proposal.md'][data-change=modified] [data-op=ins]",
               "Settings vanish."
             )

      assert has_element?(
               view,
               "[data-path='specs/api/spec.md'][data-change=added] [data-op=ins]"
             )

      assert has_element?(
               view,
               "[data-path='design.md'][data-change=removed] [data-op=del]",
               "old"
             )
    end

    test "the ends are swapped and changing them re-computes", ctx do
      versions(ctx, 3)
      assert Show.diff_ends(%{"from" => "3", "to" => "1"}, 3) == {1, 3}
      assert Show.diff_ends(%{"from" => "2", "to" => "2"}, 3) == {1, 2}
      assert Show.diff_ends(%{}, 3) == {2, 3}

      {:ok, view, _html} = open(ctx, :alice, "?tab=diff")
      render_async(view)
      assert has_element?(view, "#spec-diff-to option[selected][value='3']")

      view |> element("#spec-diff-ends") |> render_change(%{"from" => "1", "to" => "2"})
      assert_patch(view)
      render_async(view)
      assert has_element?(view, "#spec-diff-from option[selected][value='1']")
      assert has_element?(view, "#spec-diff-to option[selected][value='2']")
    end
  end

  describe "规格评审与讨论的显示" do
    test "an issue's discussion", ctx do
      versions(ctx, 1)

      review(ctx, 1, "fail", [
        %{severity: "P1", file: "specs/settings/spec.md", line: 3, body: "缺少保存失败的场景"}
      ])

      {:ok, _} =
        TaskSpecs.add_note(run_scope(ctx, ctx.fe), ctx.ident, "R1.1", %{
          resolution: "disputed",
          body: "保存失败由通用错误页处理"
        })

      {:ok, _} =
        TaskSpecs.add_note(run_scope(ctx, ctx.lead, squad: true), ctx.ident, "R1.1", %{
          resolution: "upheld",
          body: "设置页需要就地提示"
        })

      {:ok, view, _html} = open(ctx, :alice, "?tab=reviews")

      assert has_element?(view, "#review-R1 [data-verdict=fail]", "不通过")
      assert has_element?(view, "#issue-R1-1 [data-resolution=upheld]", "维持")
      assert has_element?(view, "#issue-R1-1 [data-note='1']", "keel/fe")
      assert has_element?(view, "#issue-R1-1 [data-note='1'] [data-note-resolution=disputed]")
      assert has_element?(view, "#issue-R1-1 [data-note='2']", "keel/lead")
      assert has_element?(view, "#issue-R1-1 [data-note='2'] [data-note-kind=ruling]", "裁定")
      assert has_element?(view, "#issue-R1-1 [data-location]", "specs/settings/spec.md:3")
    end

    test "only the unresolved", ctx do
      versions(ctx, 1)
      review(ctx, 1, "fail", [%{severity: "P1", body: "a"}, %{severity: "P2", body: "b"}])

      {:ok, _} =
        TaskSpecs.add_note(ctx.alice_scope, ctx.ident, "R1.1", %{resolution: "upheld", body: "x"})

      {:ok, view, _html} = open(ctx, :alice, "?tab=reviews&reviews=unresolved")
      assert has_element?(view, "#review-R1")
      refute has_element?(view, "#issue-R1-1")
      assert has_element?(view, "#issue-R1-2")

      view |> element("#spec-reviews-filter-all") |> render_click()
      assert has_element?(view, "#issue-R1-1")
    end

    test "requests and their states; a location opens the file", ctx do
      versions(ctx, 2)
      {:ok, _} = TaskSpecs.request_reviews(ctx.alice_scope, ctx.ident, [human_name(ctx)], %{})
      review(ctx, 2, "comment", [%{severity: "P3", file: "proposal.md", line: 1, body: "x"}])
      submit(ctx.alice_scope, ctx, 2, long_files(30, "v3"))

      {:ok, view, _html} = open(ctx, :alice, "?tab=reviews")
      assert has_element?(view, "#spec-request-1[data-status=cancelled]", "已取消（被新版本取代）")
      assert has_element?(view, "#review-R1 [data-for-version]", "针对 v2")

      view |> element("#issue-R1-1 [data-location]") |> render_click()
      assert_patch(view, ctx.path <> "?file=proposal.md&line=1&tab=files&v=2&view=source")
    end

    test "the history", ctx do
      versions(ctx, 1)
      propose(ctx, 1)
      {:ok, _} = TaskSpecs.reject(ctx.alice_scope, ctx.ident, %{reason: "缺少迁移方案", wake: false})

      {:ok, view, _html} = open(ctx, :alice, "?tab=history")
      assert has_element?(view, "[data-action=created]", "建立规格")
      assert has_element?(view, "[data-action=version_submitted]", "提交 v1")
      assert has_element?(view, "[data-action=finalize_proposed]", "提议以 v1 定稿")
      assert has_element?(view, "[data-action=proposal_rejected] [data-detail]", "缺少迁移方案")
    end
  end

  describe "规格页的权限" do
    test "a viewer reads and exports nothing else", ctx do
      versions(ctx, 1)

      review(ctx, 1, "fail", [
        %{severity: "P1", file: "specs/settings/spec.md", line: 3, body: "x"}
      ])

      propose_blocked =
        TaskSpecs.finalize(run_scope(ctx, ctx.lead, squad: true), ctx.ident, %{
          version: 1,
          summary: "s"
        })

      assert {:error, {:spec, :unresolved_issues, _}} = propose_blocked

      {:ok, view, _html} = open(ctx, :vic, "?file=specs/settings/spec.md&view=source")
      assert has_element?(view, "#spec-source")
      refute has_element?(view, "#spec-new-version")
      refute has_element?(view, "#spec-write-review")
      refute has_element?(view, "#spec-finalize")
      refute has_element?(view, "#spec-request-review")
      refute has_element?(view, "[id$=-add]")

      {:ok, reviews, _html} = open(ctx, :vic, "?tab=reviews")
      refute has_element?(reviews, "#issue-R1-1 button, #issue-R1-1 a[id^=issue-r1-1-]")
      refute has_element?(reviews, "[id^=issue-r1-1-]")

      {:ok, panel, _html} = open(ctx, :vic, "?panel=version")
      refute open?(panel, "spec-version-panel")

      # A note panel by URL, and a forged submit (code-review-1 P2-3).
      {:ok, note, _html} = open(ctx, :vic, "?tab=reviews&panel=note&issue=R1.1&kind=comment")
      refute open?(note, "spec-note-panel")
      render_submit(note, "note_submit", %{"note" => %{"kind" => "comment", "body" => "x"}})
      assert Process.alive?(note.pid)

      assert {:ok, %{reviews: [%{issues: [%{notes: []}]}]}} =
               TaskSpecs.reviews(ctx.alice_scope, ctx.ident)
    end

    test "no note panel on a closed spec", ctx do
      versions(ctx, 1)
      review(ctx, 1, "comment", [%{severity: "P3", body: "x"}])
      {:ok, _} = TaskSpecs.finalize(ctx.alice_scope, ctx.ident, %{version: 1, wake: false})

      {:ok, view, _html} = open(ctx, :bob, "?tab=reviews&panel=note&issue=R1.1&kind=comment")
      refute open?(view, "spec-note-panel")
      refute has_element?(view, "[id^=issue-r1-1-]")

      {:ok, open_spec, _html} = open(ctx, :alice, "?tab=reviews")
      refute has_element?(open_spec, "[id^=issue-r1-1-]")
    end

    test "only the issue's reviewer may withdraw it", ctx do
      versions(ctx, 1)
      # keel/review's owner is alice: bob may reply, alice may withdraw.
      review(ctx, 1, "fail", [%{severity: "P2", body: "x"}])
      {:ok, view, _html} = open(ctx, :bob, "?tab=reviews")

      assert has_element?(view, "#issue-r1-1-reply")
      assert has_element?(view, "#issue-r1-1-rule")
      refute has_element?(view, "#issue-r1-1-withdraw")

      {:ok, view, _html} = open(ctx, :alice, "?tab=reviews")
      assert has_element?(view, "#issue-r1-1-withdraw")
      refute has_element?(view, "#issue-r1-1-reply")
    end
  end

  describe "规格的实时刷新" do
    test "an agent's new version while following the latest", ctx do
      versions(ctx, 2)
      {:ok, view, _html} = open(ctx, :alice)
      {:ok, task_page, _html} = live(log_in_user(ctx.conn, ctx.bob), ctx.task_path)
      assert has_element?(task_page, "#task-spec-latest", "v2")

      submit(run_scope(ctx, ctx.fe), ctx, 2, long_files(30, "v3"))

      eventually(fn -> has_element?(view, "#spec-version-3.bg-hover") end)
      assert render(view) =~ "keel/fe 提交了 v3"
      refute has_element?(view, "#spec-banner-old")
      eventually(fn -> has_element?(task_page, "#task-spec-latest", "v3") end)
    end

    test "an explicit version stays", ctx do
      versions(ctx, 2)
      {:ok, view, _html} = open(ctx, :alice, "?v=2")
      submit(run_scope(ctx, ctx.fe), ctx, 2, long_files(30, "v3"))

      eventually(fn -> has_element?(view, "#spec-banner-old", "最新是 v3") end)
      assert has_element?(view, "#spec-version-2.bg-hover")
    end

    test "a new review while a reply is being written", ctx do
      versions(ctx, 1)
      review(ctx, 1, "fail", [%{severity: "P2", body: "x"}])
      {:ok, view, _html} = open(ctx, :alice, "?tab=reviews&panel=note&issue=R1.1&kind=comment")

      render_change(view, "note_change", %{"note" => %{"kind" => "comment", "body" => "草稿中"}})
      review(ctx, 1, "comment", [%{severity: "P3", body: "y"}], ctx.qa)

      eventually(fn -> has_element?(view, "#review-R2") end)
      assert open?(view, "spec-note-panel")
      assert portal_text(view, "spec-note-panel", "#spec-note-body") =~ "草稿中"
    end
  end

  defp human_name(ctx), do: ctx.bob_scope.actor.name
end
