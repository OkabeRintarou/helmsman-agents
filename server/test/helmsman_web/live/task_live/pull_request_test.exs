defmodule HelmsmanWeb.TaskLive.PullRequestTest do
  @moduledoc """
  Spec web-github PR 卡片 / 按当前提交重新验收 / 立即合并 / 重试合并 / PR 卡片实时刷新
  (add-github-ui tasks 3.1–3.5).
  """
  use HelmsmanWeb.ConnCase, async: true

  import Ecto.Query
  import ExUnit.CaptureLog
  import Phoenix.LiveViewTest
  import HelmsmanWeb.PortalHelpers
  import Helmsman.GitHubFixtures
  import Helmsman.ProjectsFixtures
  import Helmsman.PullRequestFixtures
  import Helmsman.RunsFixtures

  alias Helmsman.{Events, FakeGitHub, Projects, Repo}
  alias Helmsman.Feedback.Entry
  alias Helmsman.GitHub.{PullRequest, PullRequests}
  alias Helmsman.Projects.Project
  alias Helmsman.Runs.Run
  alias Helmsman.Tasks.TaskEvent
  alias HelmsmanWeb.TaskPullRequest

  setup %{conn: conn} do
    ctx = pr_fixture()
    fake = FakeGitHub.start()
    pushed_run(ctx, sha("c"), sha("0"))
    {:ok, _} = move(ctx.alice_scope, ctx.task, [:in_progress, :done, :verified])
    cancel_pending(ctx.task)
    Repo.delete_all(Oban.Job)

    Map.merge(ctx, %{
      conn: conn,
      fake: fake,
      path: "/w/#{ctx.workspace.slug}/t/#{ctx.task.ident}",
      full_name: "acme/app"
    })
  end

  defp open(ctx, user \\ nil) do
    {:ok, view, _html} = live(log_in_user(ctx.conn, user || ctx.alice), ctx.path)
    view
  end

  defp member(ctx, role \\ :member) do
    {user, scope} = member_scope_fixture(ctx.workspace, role)
    {user, scope}
  end

  # PR #1 on acme/app whose GitHub head is `head`.
  defp with_pr(ctx, attrs \\ %{}) do
    attrs = Map.new(attrs)
    number = Map.get(attrs, :number, 1)
    head = Map.get(attrs, :head_sha, sha("c"))
    FakeGitHub.put_pull(ctx.fake, number, %{head_ref: ctx.branch, head_sha: head})
    pr = pr_row(ctx, Map.merge(%{number: number, head_sha: head}, attrs))
    Map.put(ctx, :pr, pr)
  end

  defp set_pr(ctx, changes), do: Repo.update_all(where(PullRequest, id: ^ctx.pr.id), set: changes)

  # The review agent pushed `sha` after the verification: the pull request is stale.
  defp stale(ctx, sha) do
    pushed_run(ctx, sha, sha("c"))
    FakeGitHub.change_pull(ctx.fake, 1, head_sha: sha)
    set_pr(ctx, head_sha: sha, merge_status: :stale, merge_reason: :head_changed)
    ctx
  end

  defp history_count(ctx),
    do: Repo.aggregate(from(e in TaskEvent, where: e.task_id == ^ctx.task.id), :count)

  defp flash(view, kind), do: view |> element("#flash-#{kind}") |> render()

  defp pull_requests_changed(ctx),
    do:
      Events.broadcast(Events.topic(:task, ctx.task.id), {:pull_request_changed, ctx.task.ident})

  defp rebind(ctx, repository_id) do
    {:ok, _} =
      Projects.update_github_settings(ctx.alice_scope, ctx.project.key, %{
        repository_id: repository_id
      })

    :ok
  end

  defp api_repository(ctx),
    do: repository_fixture(ctx.installation, %{owner: "acme", name: "api"})

  describe "PR 卡片" do
    test "等待 CI", ctx do
      ctx =
        with_pr(ctx,
          number: 34,
          merge_status: :waiting,
          merge_reason: :ci_pending,
          checks_state: :pending
        )

      view = open(ctx)

      assert has_element?(view, "#task-pr-state", "可评审")

      assert has_element?(
               view,
               ~s(#task-pr-link[target="_blank"][rel="noopener noreferrer"]),
               "#34"
             )

      assert has_element?(view, "#task-pr-repository", "acme/app")
      assert has_element?(view, "#task-pr-checks [data-checks=pending]", "进行中")
      assert has_element?(view, "#task-pr-verdict", "等待 CI")
    end

    test "CI 失败的检查名", ctx do
      ctx =
        with_pr(ctx,
          checks_state: :failure,
          checks: %{
            "head_sha" => sha("c"),
            "total" => 6,
            "passed" => 4,
            "pending" => 0,
            "failed" => ["test (ubuntu)", "lint"]
          }
        )

      view = open(ctx)
      assert has_element?(view, "#task-pr-checks [data-checks=failure]", "失败")
      assert has_element?(view, "#task-pr-checks [data-checks-passed]", "4/6 通过")
      assert has_element?(view, "#task-pr-failed-checks li", "test (ubuntu)")
      assert has_element?(view, "#task-pr-failed-checks li", "lint")
    end

    test "已合并", ctx do
      ctx =
        with_pr(ctx,
          state: :merged,
          merge_status: :merged,
          merged_sha: sha("e"),
          merged_at: DateTime.add(DateTime.utc_now(), -7200)
        )

      view = open(ctx)
      assert has_element?(view, "#task-pr-state", "已合并")
      assert has_element?(view, "#task-pr-merged code", "eeeeeee")
      assert has_element?(view, "#task-pr-verdict", "已合并到 main")
      assert has_element?(view, "#task-pr-verdict time", "2 小时前")
      refute has_element?(view, "#task-pr-actions")
    end

    test "不独立", ctx do
      ctx = with_pr(ctx, merge_status: :blocked, merge_reason: :not_independent)
      view = open(ctx)
      assert has_element?(view, "#task-pr-verdict [data-verdict]", "已阻止")
      assert has_element?(view, "#task-pr-verdict", "验收不独立")
    end

    test "GitHub 拒绝合并", ctx do
      note = "At least 1 approving review is required. <b>Resolve</b> it on GitHub."
      ctx = with_pr(ctx, merge_status: :blocked, merge_reason: :merge_rejected, merge_note: note)
      view = open(ctx)

      assert has_element?(view, "#task-pr-verdict", "需要在 GitHub 上处理")
      assert has_element?(view, "#task-pr-note summary", "GitHub 的说明")
      html = view |> element("#task-pr-note") |> render()
      assert html =~ "&lt;b&gt;Resolve&lt;/b&gt;"
      refute html =~ "<b>"
    end

    test "验收后有新提交", ctx do
      ctx |> with_pr() |> stale(sha("d"))
      view = open(ctx)

      assert has_element?(view, "#task-pr-verdict", "验收后有新提交")
      assert has_element?(view, "#task-pr-verified [data-stale]", "ccccccc")
      assert has_element?(view, "#task-pr-head code", "ddddddd")
    end

    test "还没有 PR", ctx do
      view = open(ctx)
      assert has_element?(view, "#task-pr-empty", "推送提交后会自动创建草稿 PR")
    end

    test "仓库不可用时警示", ctx do
      Repo.update_all(where(Helmsman.GitHub.Repository, id: ^ctx.repository.id),
        set: [removed_at: DateTime.utc_now()]
      )

      view = open(ctx)
      assert has_element?(view, "#task-pr-empty", "仓库 acme/app 不可用，不会开 PR")
    end

    test "项目未绑定仓库", ctx do
      project_fixture(ctx.alice_scope, key: "DOC", name: "Docs")
      task_fixture(ctx.alice_scope, "DOC")

      {:ok, view, _html} =
        live(log_in_user(ctx.conn, ctx.alice), "/w/#{ctx.workspace.slug}/t/DOC-1")

      refute has_element?(view, "#task-pr")
    end

    test "已登记的立即合并请求与自动重开", ctx do
      ctx = with_pr(ctx, auto_reopen_count: 1)
      {:ok, _} = PullRequests.merge_now(ctx.alice_scope, ctx.task.ident)
      view = open(ctx)

      assert has_element?(view, "#task-pr-merge-request", "请求了立即合并")
      refute has_element?(view, "#task-pr-merge-request [data-skip]")
      assert has_element?(view, "#task-pr-reopens", "1 / 3")
    end
  end

  describe "按当前提交重新验收" do
    setup ctx, do: ctx |> with_pr() |> stale(sha("d"))

    test "重新验收", ctx do
      {user, _scope} = member(ctx)
      view = open(ctx, user)
      before = history_count(ctx)

      view |> element("#task-pr-reverify") |> render_click()
      assert open?(view, "pr-reverify-confirm")

      assert in_portal?(
               view,
               "pr-reverify-confirm",
               "#pr-reverify-confirm-description",
               "ddddddd"
             )

      render_click(view, "pr_confirm_reverify")
      render_async(view)

      assert flash(view, :info) =~ "已按 ddddddd 重新验收 acme/app#1"
      refute open?(view, "pr-reverify-confirm")
      assert history_count(ctx) == before + 1
      last = "#history-#{before}"
      assert has_element?(view, last, "重新验收")
      refute has_element?(view, last <> " [data-from]")
      assert has_element?(view, last <> " [data-verified-sha] code", "ddddddd")
      refute has_element?(view, "#task-pr-reverify", "重新验收中")
    end

    test "确认之后有了新提交", ctx do
      view = open(ctx)
      view |> element("#task-pr-reverify") |> render_click()

      # A run pushes e before the request reaches GitHub; the page has not heard of it.
      pushed_run(ctx, sha("e"), sha("d"))
      FakeGitHub.change_pull(ctx.fake, 1, head_sha: sha("e"))
      before = history_count(ctx)

      render_click(view, "pr_confirm_reverify")
      render_async(view)

      text = flash(view, :error)
      assert text =~ "PR 有了新提交（eeeeeee），没有重新验收；请查看后重新确认"
      refute text =~ "ddddddd"
      assert history_count(ctx) == before
      refute has_element?(view, "#task-pr-reverify[disabled]")
    end

    test "手动推送的提交", ctx do
      FakeGitHub.change_pull(ctx.fake, 1, head_sha: sha("f"))
      set_pr(ctx, head_sha: sha("f"))
      view = open(ctx)
      before = history_count(ctx)

      view |> element("#task-pr-reverify") |> render_click()
      render_click(view, "pr_confirm_reverify")
      render_async(view)

      assert flash(view, :error) =~ "PR 的最新提交不是 Helmsman 运行推送的"
      assert history_count(ctx) == before
    end

    test "重新验收进行中", ctx do
      test = self()

      FakeGitHub.update(ctx.fake, fn s ->
        %{
          s
          | fail: fn
              "GET", "/repos/acme/app/pulls/1" ->
                send(test, {:blocked, self()})

                receive do
                  :release -> nil
                end

              _method, _path ->
                nil
            end
        }
      end)

      view = open(ctx)
      view |> element("#task-pr-reverify") |> render_click()
      render_click(view, "pr_confirm_reverify")
      assert_receive {:blocked, pid}, 2000

      assert has_element?(view, "#task-pr-reverify[disabled]", "重新验收中…")
      assert has_element?(view, "#task-pr-merge-now[disabled]")

      # The page keeps updating: a new run of the task shows up.
      run = run_fixture(ctx.agent, %{task_id: ctx.task.id, status: :queued})
      Events.broadcast(Events.topic(:task, ctx.task.id), {:runs_changed, ctx.task.ident})
      send(view.pid, :reload_runs)
      assert has_element?(view, "#run-card-#{run.id}")
      assert has_element?(view, "#task-pr-reverify[disabled]", "重新验收中…")

      # Clicking again sends nothing.
      render_click(view, "pr_ask_reverify")
      refute open?(view, "pr-reverify-confirm")
      render_click(view, "pr_confirm_reverify")

      send(pid, :release)
      render_async(view)

      gets =
        Enum.count(
          FakeGitHub.requests(ctx.fake),
          &(&1 == %{method: "GET", path: "/repos/acme/app/pulls/1"})
        )

      assert gets == 1
      assert flash(view, :info) =~ "已按 ddddddd 重新验收"
      refute has_element?(view, "#task-pr-reverify", "重新验收中")
    end

    test "GitHub 不可达", ctx do
      FakeGitHub.update(ctx.fake, fn s ->
        %{
          s
          | fail: fn
              "GET", "/repos/acme/app/pulls/1" -> {503, %{"message" => "Unavailable"}}
              _method, _path -> nil
            end
        }
      end)

      view = open(ctx)
      before = history_count(ctx)
      view |> element("#task-pr-reverify") |> render_click()
      render_click(view, "pr_confirm_reverify")
      render_async(view)

      assert flash(view, :error) =~ "暂时无法连接 GitHub，没有重新验收，请稍后重试"
      assert has_element?(view, "#task-pr-reverify", "按当前提交重新验收")
      refute has_element?(view, "#task-pr-reverify[disabled]")
      assert history_count(ctx) == before
    end

    test "the request exits", ctx do
      FakeGitHub.update(ctx.fake, fn s ->
        %{
          s
          | fail: fn
              "GET", "/repos/acme/app/pulls/1" -> raise "boom"
              _method, _path -> nil
            end
        }
      end)

      view = open(ctx)
      view |> element("#task-pr-reverify") |> render_click()

      log =
        capture_log(fn ->
          render_click(view, "pr_confirm_reverify")
          render_async(view)
        end)

      assert log =~ "Re-verifying"
      assert flash(view, :error) =~ "重新验收失败，请重试"
      refute has_element?(view, "#task-pr-reverify[disabled]")
    end

    test "viewer", ctx do
      {user, _scope} = member(ctx, :viewer)
      view = open(ctx, user)
      assert has_element?(view, "#task-pr-verdict", "验收后有新提交")
      refute has_element?(view, "#task-pr-reverify")
      refute has_element?(view, "#task-pr-merge-now")
    end

    test "the head changes while the dialog is open", ctx do
      view = open(ctx)
      view |> element("#task-pr-reverify") |> render_click()
      assert open?(view, "pr-reverify-confirm")

      pushed_run(ctx, sha("e"), sha("d"))
      set_pr(ctx, head_sha: sha("e"))
      pull_requests_changed(ctx)

      refute open?(view, "pr-reverify-confirm")
      assert flash(view, :error) =~ "PR 已变化，请重新确认"

      render_click(view, "pr_confirm_reverify")
      render_async(view)
      refute FakeGitHub.requested?(ctx.fake, "GET", "/pulls/1")
    end

    # The domain committed; the page handles a notification before the result.
    defp pause_after_domain(ctx) do
      test = self()

      # Other points of the same hook (the domain's `:reverify_locking`) pass through.
      hook = fn
        {:reverified, _result} ->
          send(test, {:reverified, self()})

          receive do
            :go -> :ok
          end

        _point ->
          :ok
      end

      FakeGitHub.update(ctx.fake, fn s ->
        %{
          s
          | fail: fn
              "GET", "/repos/acme/app/pulls/1" ->
                Process.put(:helmsman_test_hook, hook)
                nil

              _method, _path ->
                nil
            end
        }
      end)
    end

    test "进行中换了 PR（改绑通知先到）", ctx do
      api = api_repository(ctx)
      pr_row(ctx, %{repository: api, number: 7, head_sha: sha("a")})
      pause_after_domain(ctx)
      view = open(ctx)

      view |> element("#task-pr-reverify") |> render_click()
      render_click(view, "pr_confirm_reverify")
      assert_receive {:reverified, pid}, 2000
      assert latest_verification(ctx.task).verified_sha == sha("d")

      :ok = rebind(ctx, api.id)
      assert has_element?(view, "#task-pr-repository", "acme/api")
      assert has_element?(view, "#task-pr-link", "#7")

      send(pid, :go)
      render_async(view)

      text = flash(view, :info)
      assert text =~ "已按 ddddddd 重新验收 acme/app#1"
      assert text =~ "（PR 已变化，卡片显示的是当前的 PR）"
      assert has_element?(view, "#task-pr-link", "#7")
      refute render(view) =~ "重新验收中"
      assert :sys.get_state(view.pid).socket.assigns.task_pr.operation == nil
    end

    test "进行中头部变化（通知先到）", ctx do
      pause_after_domain(ctx)
      view = open(ctx)

      view |> element("#task-pr-reverify") |> render_click()
      render_click(view, "pr_confirm_reverify")
      assert_receive {:reverified, pid}, 2000

      pushed_run(ctx, sha("e"), sha("d"))
      set_pr(ctx, head_sha: sha("e"))
      pull_requests_changed(ctx)
      assert has_element?(view, "#task-pr-head code", "eeeeeee")

      send(pid, :go)
      render_async(view)

      text = flash(view, :info)
      assert text =~ "已按 ddddddd 重新验收 acme/app#1"
      refute text =~ "PR 已变化"
      assert has_element?(view, "#task-pr-head code", "eeeeeee")
      assert :sys.get_state(view.pid).socket.assigns.task_pr.operation == nil
    end
  end

  describe "handle_async/4" do
    test "a result of another operation is ignored" do
      state = %{operation: %{id: 2, kind: :reverify, pr_key: {"acme/app", 1}, head_sha: "d"}}
      socket = %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}, task_pr: state}}

      assert TaskPullRequest.handle_async(
               :pr_reverify,
               {:ok, {1, {:ok, %{verified_sha: "d"}}}},
               socket,
               fn _ -> flunk("refreshed") end
             ) == socket
    end
  end

  describe "立即合并" do
    test "手动策略下立即合并", ctx do
      Repo.update_all(where(Project, id: ^ctx.project.id), set: [merge_policy: "manual"])
      ctx = with_pr(ctx, merge_status: :none, merge_reason: :policy_manual)
      {user, _scope} = member(ctx)
      view = open(ctx, user)

      assert has_element?(view, "#task-pr-verdict", "手动合并")
      view |> element("#task-pr-merge-now") |> render_click()
      assert open?(view, "pr-merge-confirm")
      assert in_portal?(view, "pr-merge-confirm", "#pr-merge-confirm-title", "立即合并 acme/app#1？")
      assert in_portal?(view, "pr-merge-confirm", "#pr-merge-confirm-confirm", "立即合并")

      render_click(view, "pr_merge_now")
      assert flash(view, :info) =~ "已提交，合并结果稍后显示在 PR 卡片"
      assert has_element?(view, "#task-pr-merge-request", "#{user.display_name} 请求了立即合并")
    end

    test "owner 跳过独立性", ctx do
      ctx = with_pr(ctx, merge_status: :blocked, merge_reason: :not_independent)
      view = open(ctx)

      view |> element("#task-pr-merge-now") |> render_click()
      assert in_portal?(view, "pr-merge-confirm", "#pr-merge-confirm-confirm", "填写原因并合并")
      render_click(view, "pr_open_skip")
      refute open?(view, "pr-merge-confirm")
      assert open?(view, "pr-skip-panel")
      assert in_portal?(view, "pr-skip-panel", "p", "原因会以系统身份记入任务的 Feedback")

      render_submit(view, "pr_skip_submit", %{"skip" => %{"reason" => "hotfix"}})
      refute open?(view, "pr-skip-panel")
      assert has_element?(view, "#task-pr-merge-request [data-skip]", "跳过独立性检查")

      assert Repo.exists?(
               from(e in Entry, where: e.task_id == ^ctx.task.id and like(e.content, "%hotfix%"))
             )

      assert render(view) =~ "hotfix"
    end

    test "原因为空 / 太长", ctx do
      ctx = with_pr(ctx, merge_status: :blocked, merge_reason: :not_independent)
      view = open(ctx)
      view |> element("#task-pr-merge-now") |> render_click()
      render_click(view, "pr_open_skip")

      render_submit(view, "pr_skip_submit", %{"skip" => %{"reason" => "  "}})
      assert in_portal?(view, "pr-skip-panel", "#pr-skip-form", "不能为空")

      render_submit(view, "pr_skip_submit", %{"skip" => %{"reason" => String.duplicate("原", 334)}})

      assert in_portal?(view, "pr-skip-panel", "#pr-skip-form", "不能超过 1000 字节")
      assert open?(view, "pr-skip-panel")
      assert Repo.reload!(ctx.pr).merge_request == nil
    end

    test "admin 不能跳过独立性", ctx do
      ctx = with_pr(ctx, merge_status: :blocked, merge_reason: :not_independent)
      {user, _scope} = member(ctx, :admin)
      view = open(ctx, user)

      view |> element("#task-pr-merge-now") |> render_click()
      assert in_portal?(view, "pr-merge-confirm", "#pr-merge-confirm-confirm", "立即合并")
      refute in_portal?(view, "pr-merge-confirm", "button", "填写原因并合并")
      render_click(view, "pr_open_skip")
      refute open?(view, "pr-skip-panel")
    end
  end

  # code-review-3 P1-1 / R7: the binding changed and committed, but the page has not
  # handled the notification yet (or the confirmation is ahead of it in the mailbox).
  describe "确认的 PR 已被换掉、通知还没处理" do
    defp rebind_silently(ctx, repository),
      do:
        Repo.update_all(where(Project, id: ^ctx.project.id), set: [repository_id: repository.id])

    defp with_two_prs(ctx, attrs) do
      ctx = with_pr(ctx, attrs)
      api = api_repository(ctx)

      other =
        pr_row(ctx, Map.merge(%{repository: api, number: 7, head_sha: sha("c")}, Map.new(attrs)))

      Map.merge(ctx, %{api: api, other: other})
    end

    defp feedback_count(ctx),
      do: Repo.aggregate(from(f in Entry, where: f.task_id == ^ctx.task.id), :count)

    test "立即合并不登记到新的 PR", ctx do
      ctx = with_two_prs(ctx, merge_status: :none, merge_reason: :policy_manual)
      view = open(ctx)
      view |> element("#task-pr-merge-now") |> render_click()
      assert open?(view, "pr-merge-confirm")

      rebind_silently(ctx, ctx.api)
      render_click(view, "pr_merge_now")

      assert Repo.reload!(ctx.pr).merge_request == nil
      assert Repo.reload!(ctx.other).merge_request == nil
      assert flash(view, :error) =~ "PR 已变化，请重新确认"
      refute open?(view, "pr-merge-confirm")
      assert has_element?(view, "#task-pr-link", "#7")
    end

    test "跳过独立性不登记、不写系统评论", ctx do
      ctx = with_two_prs(ctx, merge_status: :blocked, merge_reason: :not_independent)
      view = open(ctx)
      view |> element("#task-pr-merge-now") |> render_click()
      render_click(view, "pr_open_skip")
      before = feedback_count(ctx)

      rebind_silently(ctx, ctx.api)
      render_submit(view, "pr_skip_submit", %{"skip" => %{"reason" => "hotfix"}})

      assert Repo.reload!(ctx.pr).merge_request == nil
      assert Repo.reload!(ctx.other).merge_request == nil
      assert feedback_count(ctx) == before
      assert flash(view, :error) =~ "PR 已变化，请重新确认"
      refute open?(view, "pr-skip-panel")
    end

    test "重新验收不写到新的 PR", ctx do
      ctx = ctx |> with_two_prs(%{}) |> stale(sha("d"))

      Repo.update_all(where(PullRequest, id: ^ctx.other.id),
        set: [head_sha: sha("d"), merge_status: :stale, merge_reason: :head_changed]
      )

      view = open(ctx)
      view |> element("#task-pr-reverify") |> render_click()
      before = history_count(ctx)

      rebind_silently(ctx, ctx.api)
      render_click(view, "pr_confirm_reverify")
      render_async(view)

      assert history_count(ctx) == before
      assert flash(view, :error) =~ "PR 已变化，请重新确认"
      refute has_element?(view, "#task-pr-reverify[disabled]")
    end

    test "the confirmed pull request is passed to the domain", ctx do
      ctx = with_pr(ctx, merge_status: :none, merge_reason: :policy_manual)
      view = open(ctx)
      view |> element("#task-pr-merge-now") |> render_click()
      render_click(view, "pr_merge_now")

      assert flash(view, :info) =~ "已提交"
      assert Repo.reload!(ctx.pr).merge_request != nil
    end
  end

  describe "重试合并" do
    test "CI 超时后重试", ctx do
      ctx =
        with_pr(ctx,
          merge_status: :blocked,
          merge_reason: :ci_timeout,
          waiting_since: DateTime.utc_now()
        )

      {user, _scope} = member(ctx)
      view = open(ctx, user)

      assert has_element?(view, "#task-pr-verdict", "CI 6 小时内没有结果")
      view |> element("#task-pr-retry") |> render_click()
      assert flash(view, :info) =~ "已重试"
      assert has_element?(view, "#task-pr-retry", "已重试")
      assert Repo.reload!(ctx.pr).waiting_since == nil

      send(view.pid, :pr_retried)
      assert has_element?(view, "#task-pr-retry", "重试")
      refute has_element?(view, "#task-pr-retry", "已重试")
    end

    test "no retry while waiting", ctx do
      ctx = with_pr(ctx, merge_status: :waiting, merge_reason: :ci_pending)
      view = open(ctx)
      refute has_element?(view, "#task-pr-retry")
    end
  end

  describe "PR 卡片实时刷新" do
    test "对账开出 PR", ctx do
      view = open(ctx)
      assert has_element?(view, "#task-pr-empty")

      pr_row(ctx, %{number: 34, state: :draft, head_sha: sha("c")})
      pull_requests_changed(ctx)

      assert has_element?(view, "#task-pr-state", "草稿")
      assert has_element?(view, "#task-pr-link", "#34")
    end

    test "合并完成", ctx do
      ctx = with_pr(ctx, merge_status: :waiting, merge_reason: :ci_pending)
      view = open(ctx)
      assert has_element?(view, "#task-pr-actions")

      set_pr(ctx,
        state: :merged,
        merge_status: :merged,
        merge_reason: nil,
        merged_sha: sha("e"),
        merged_at: DateTime.utc_now()
      )

      pull_requests_changed(ctx)
      assert has_element?(view, "#task-pr-state", "已合并")
      refute has_element?(view, "#task-pr-actions")
    end

    test "改绑后旧 PR 消失", ctx do
      ctx = with_pr(ctx, number: 34)
      api = api_repository(ctx)
      view = open(ctx)
      assert has_element?(view, "#task-pr-link", "#34")

      :ok = rebind(ctx, api.id)
      assert has_element?(view, "#task-pr-empty")
      refute has_element?(view, "#task-pr-link")
      refute has_element?(view, "#task-pr-actions")
    end

    test "改绑到已有 PR 的仓库", ctx do
      ctx = with_pr(ctx, number: 34)
      api = api_repository(ctx)
      pr_row(ctx, %{repository: api, number: 7, head_sha: sha("a")})
      view = open(ctx)

      :ok = rebind(ctx, api.id)
      assert has_element?(view, "#task-pr-repository", "acme/api")
      assert has_element?(view, "#task-pr-link", "#7")
    end

    test "解绑", ctx do
      ctx = with_pr(ctx, number: 34)
      view = open(ctx)
      :ok = rebind(ctx, nil)
      refute has_element?(view, "#task-pr")
    end

    test "确认期间改绑", ctx do
      ctx = with_pr(ctx, number: 34)
      api = api_repository(ctx)
      {user, _scope} = member(ctx)
      view = open(ctx, user)

      view |> element("#task-pr-merge-now") |> render_click()
      assert open?(view, "pr-merge-confirm")

      :ok = rebind(ctx, api.id)
      refute open?(view, "pr-merge-confirm")
      assert flash(view, :error) =~ "PR 已变化，请重新确认"

      render_click(view, "pr_merge_now")
      assert Repo.reload!(ctx.pr).merge_request == nil
    end

    test "跳过独立性面板打开时改绑", ctx do
      ctx = with_pr(ctx, merge_status: :blocked, merge_reason: :not_independent)
      api = api_repository(ctx)
      view = open(ctx)

      view |> element("#task-pr-merge-now") |> render_click()
      render_click(view, "pr_open_skip")
      assert open?(view, "pr-skip-panel")

      :ok = rebind(ctx, api.id)
      refute open?(view, "pr-skip-panel")
      assert flash(view, :error) =~ "PR 已变化，请重新确认"

      render_submit(view, "pr_skip_submit", %{"skip" => %{"reason" => "hotfix"}})
      assert Repo.reload!(ctx.pr).merge_request == nil
    end

    test "运行结束后可以重新验收", ctx do
      ctx |> with_pr() |> stale(sha("d"))
      run = pushed_run(ctx, sha("d"), sha("c"), status: :running)
      view = open(ctx)

      assert has_element?(view, "#task-pr-verdict", "验收后有新提交")
      refute has_element?(view, "#task-pr-reverify")

      Repo.update_all(where(Run, id: ^run.id),
        set: [status: :succeeded, finished_at: DateTime.utc_now()]
      )

      Events.broadcast(Events.topic(:task, ctx.task.id), {:runs_changed, ctx.task.ident})
      send(view.pid, :reload_runs)
      assert has_element?(view, "#task-pr-reverify", "按当前提交重新验收")
    end
  end
end
