defmodule HelmsmanWeb.TaskLive.VerifyPreviewTest do
  @moduledoc """
  Spec web-github 验收面板的合并预告 and 历史中的验收提交 (add-github-ui tasks 4.1, 4.2).
  """
  use HelmsmanWeb.ConnCase, async: true

  import Ecto.Query
  import Phoenix.LiveViewTest
  import HelmsmanWeb.PortalHelpers
  import Helmsman.PullRequestFixtures
  import Helmsman.RunsFixtures

  alias Helmsman.{FakeGitHub, Repo}
  alias Helmsman.GitHub.PullRequests
  alias Helmsman.Runs.Run
  alias Helmsman.Tasks.Task

  @panel "transition-panel"

  setup %{conn: conn} do
    ctx = pr_fixture()
    {:ok, _} = move(ctx.alice_scope, ctx.task, [:in_progress, :done])
    cancel_pending(ctx.task)
    Map.merge(ctx, %{conn: conn, path: "/w/#{ctx.workspace.slug}/t/#{ctx.task.ident}"})
  end

  defp open_verify(ctx, user) do
    {:ok, view, _html} = live(log_in_user(ctx.conn, user), ctx.path)
    view |> element("#transition-verified") |> render_click()
    assert open?(view, @panel)
    view
  end

  defp preview(view, selector),
    do: portal_text(view, @panel, "#verify-merge-preview #{selector}")

  describe "验收面板的合并预告" do
    test "独立的验收人", ctx do
      pushed_run(ctx, sha("3"), sha("0"))
      view = open_verify(ctx, ctx.alice)

      assert preview(view, "[data-commit]") =~ "3333333"
      assert preview(view, "[data-outcome=auto_merge]") =~ "CI 通过后自动合并到 main"
      assert preview(view, "[data-checks]") =~ "无检查"
    end

    test "执行方自验收", ctx do
      pushed_run(ctx, sha("3"), sha("0"))
      {bob, bob_scope} = member_scope_fixture(ctx.workspace)

      Repo.update_all(where(Task, id: ^ctx.task.id), set: [assignee_id: bob_scope.actor.id])

      view = open_verify(ctx, bob)
      assert preview(view, "[data-outcome=not_independent]") =~ "不会自动合并"
    end

    test "没有推送", ctx do
      view = open_verify(ctx, ctx.alice)
      assert preview(view, "[data-commit]") =~ "还没有运行推送的提交，验收不会记下提交，也不会自动合并"
      refute in_portal?(view, @panel, "[data-outcome]")
    end

    test "项目未绑定仓库时不显示", ctx do
      Repo.update_all(where(Helmsman.Projects.Project, id: ^ctx.project.id),
        set: [repository_id: nil]
      )

      view = open_verify(ctx, ctx.alice)
      refute in_portal?(view, @panel, "#verify-merge-preview")
    end

    test "other panels have no preview", ctx do
      {:ok, view, _html} = live(log_in_user(ctx.conn, ctx.alice), ctx.path)
      view |> element("#transition-in_progress") |> render_click()
      refute in_portal?(view, @panel, "#verify-merge-preview")
    end
  end

  describe "历史中的验收提交" do
    test "重新验收条目", ctx do
      fake = FakeGitHub.start()
      pushed_run(ctx, sha("c"), sha("0"))
      {:ok, _} = move(ctx.alice_scope, ctx.task, [:verified])
      head = "c4f00d1e" <> String.duplicate("0", 32)
      pushed_run(ctx, head, sha("c"))
      Repo.update_all(where(Run, task_id: ^ctx.task.id), set: [status: :succeeded])
      FakeGitHub.put_pull(fake, 1, %{head_ref: ctx.branch, head_sha: head})
      pr_row(ctx, %{number: 1, head_sha: head, merge_status: :stale, merge_reason: :head_changed})

      {:ok, %{verified_sha: ^head}} = PullRequests.reverify(ctx.alice_scope, ctx.task.ident)

      {:ok, view, _html} = live(log_in_user(ctx.conn, ctx.alice), ctx.path)
      events = Repo.aggregate(where(Helmsman.Tasks.TaskEvent, task_id: ^ctx.task.id), :count)
      last = "#history-#{events - 1}"

      assert has_element?(view, last <> " [data-reverified]", "重新验收")
      refute has_element?(view, last <> " [data-from]")
      assert has_element?(view, last, ctx.alice.display_name)
      assert has_element?(view, last <> " [data-verified-sha] code", "c4f00d1")
      assert has_element?(view, last <> ~s( button[data-copy="#{head}"]))

      # The first verification shows its commit, as an ordinary transition.
      first = "#history-3"
      assert has_element?(view, first <> " [data-to]", "已验收")
      assert has_element?(view, first <> " [data-verified-sha] code", "ccccccc")
    end
  end
end
