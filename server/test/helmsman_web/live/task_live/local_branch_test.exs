defmodule HelmsmanWeb.TaskLive.LocalBranchTest do
  @moduledoc """
  Spec web-local-repositories 任务的本地分支卡片, 标记已合并与检查合并状态, 指派到其他机器的提示
  and the task page part of 本地仓库界面的实时刷新 (add-local-repositories-ui D7, D8,
  D10, D11; tasks 3.1–3.3, 3.5, 3.6).
  """
  use HelmsmanWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import HelmsmanWeb.PortalHelpers
  import HelmsmanWeb.LiveHelpers
  import Helmsman.AgentsFixtures
  import Helmsman.LocalRepositoriesFixtures
  import Helmsman.ProjectsFixtures
  import Helmsman.RunsFixtures

  alias Helmsman.{Events, LocalRepositories, Repo, Tx}
  alias HelmsmanWeb.TaskLive.Show

  @path "/home/alice/code/app"
  @a String.duplicate("a1b2c3d4", 5)
  @b String.duplicate("b2c3d4e5", 5)
  @c String.duplicate("c3d4e5f6", 5)
  @panel "local-merge-panel"

  setup %{conn: conn} do
    ctx = local_run_fixture()
    daemon = ctx.daemon |> Ecto.Changeset.change(name: "alice-mbp") |> Repo.update!()
    {bob, bob_scope} = member_scope_fixture(ctx.workspace)
    {viewer, _} = member_scope_fixture(ctx.workspace, :viewer)

    Map.merge(ctx, %{
      conn: conn,
      daemon: daemon,
      users: %{alice: ctx.alice, bob: bob, viewer: viewer},
      bob_scope: bob_scope,
      task_path: "/w/#{ctx.workspace.slug}/t/#{ctx.task.ident}"
    })
  end

  defp open(ctx, who \\ :alice), do: live(log_in_user(ctx.conn, ctx.users[who]), ctx.task_path)

  defp deliver(ctx, attrs \\ %{}), do: task_local_branch_fixture(ctx.task, ctx.local_repo, attrs)

  defp state(view), do: :sys.get_state(view.pid).socket.assigns.local_branch

  defp notify(ctx),
    do:
      Events.broadcast(Events.topic(:task, ctx.task.id), {:local_branch_changed, ctx.task.ident})

  defp branch_state(ctx), do: local_branch(ctx.task.id).state

  describe "the card (3.1)" do
    test "delivered, not merged", ctx do
      deliver(ctx)
      {:ok, view, _html} = open(ctx)

      assert has_element?(view, "#task-local-branch h2", "本地分支")
      assert has_element?(view, "#task-local-branch-state", "未合并")
      assert has_element?(view, "#task-local-branch-chip [data-local-repository]", "app")
      assert has_element?(view, "#task-local-branch-chip [data-machine]", "alice-mbp")
      assert has_element?(view, "#task-local-branch-name", ctx.branch)
      assert has_element?(view, "#task-local-branch-head", "a1b2c3d")
      assert has_element?(view, "#task-local-branch-copy-head[data-copy='#{@a}']")
      assert has_element?(view, "#task-local-branch-base", "main")

      assert has_element?(
               view,
               "#task-local-branch-cmd-log-text",
               "git -C #{@path} log --oneline main..#{ctx.branch}"
             )

      assert has_element?(
               view,
               "#task-local-branch-cmd-merge-text",
               "git -C #{@path} switch main && git -C #{@path} merge --no-ff #{ctx.branch}"
             )

      assert has_element?(view, "#task-local-branch-merge-note", "会把该仓库当前检出的分支切换为 main 再合并")
      refute has_element?(view, "#task-local-branch-where")
    end

    test "the merge command targets the base branch, not the checked out one", ctx do
      ctx.local_repo |> Ecto.Changeset.change(default_branch: "release") |> Repo.update!()
      bind_local(ctx.project, ctx.local_repo, "main")
      deliver(ctx)
      {:ok, view, _html} = open(ctx)

      assert has_element?(view, "#task-local-branch-cmd-merge-text", "switch main && ")
      assert has_element?(view, "#task-local-branch-merge-note", "main 已在另一个 worktree 中检出")
      assert has_element?(view, "#task-local-branch-merge-note", "bare 仓库")
    end

    test "a member who cannot see the path", ctx do
      deliver(ctx)
      {:ok, view, html} = open(ctx, :bob)

      assert has_element?(
               view,
               "#task-local-branch-cmd-merge-text",
               "git switch main && git merge --no-ff #{ctx.branch}"
             )

      assert has_element?(view, "#task-local-branch-where", "在 alice-mbp 上仓库 app 的目录中执行")
      refute html =~ @path
      refute inspect(:sys.get_state(view.pid)) =~ @path
    end

    test "not delivered yet", ctx do
      {:ok, view, _html} = open(ctx)

      assert has_element?(
               view,
               "#task-local-branch-pending",
               "运行成功收尾后，任务分支会出现在 alice-mbp 上的仓库 app 里"
             )

      refute has_element?(view, "#task-local-branch-commands")
      refute has_element?(view, "#task-local-branch-state")
      refute has_element?(view, "#task-local-branch-actions")
    end

    test "marked merged by a person", ctx do
      deliver(ctx)
      {:ok, marked} = LocalRepositories.mark_merged(ctx.alice_scope, ctx.task.ident, "squash 合并")
      {:ok, view, _html} = open(ctx)

      assert has_element?(view, "#task-local-branch-state", "已合并")

      assert has_element?(
               view,
               "#task-local-branch-merged [data-marked]",
               "#{marked.merged_by.name} 标记为已合并"
             )

      assert has_element?(view, "#task-local-branch-note", "squash 合并")
      assert has_element?(view, "#task-local-branch-cmd-log")
      refute has_element?(view, "#task-local-branch-cmd-merge")
      refute has_element?(view, "#task-local-branch-merge-note")
    end

    test "a GitHub project's task has no card", ctx do
      other = project_fixture(ctx.alice_scope)
      task = task_fixture(ctx.alice_scope, other.key)

      {:ok, view, _html} =
        live(log_in_user(ctx.conn, ctx.alice), "/w/#{ctx.workspace.slug}/t/#{task.ident}")

      refute has_element?(view, "#task-local-branch")
    end

    test "without a base branch there are no commands", ctx do
      ctx.local_repo |> Ecto.Changeset.change(default_branch: nil) |> Repo.update!()
      deliver(ctx)
      {:ok, view, _html} = open(ctx)

      assert has_element?(view, "#task-local-branch-base", "—")
      assert has_element?(view, "#task-local-branch-no-base", "设置基础分支后显示审查命令")
      refute has_element?(view, "#task-local-branch-commands")
    end

    test "a branch of the repository the project was bound to before", ctx do
      deliver(ctx)
      other = local_repository_fixture(ctx.workspace, ctx.daemon, %{name: "web", path: "/x/web"})
      bind_local(ctx.project, other)
      {:ok, view, _html} = open(ctx)

      assert has_element?(view, "#task-local-branch-chip [data-local-repository]", "app")
      assert has_element?(view, "#task-local-branch-rebound", "项目已改绑：这是交付到原仓库的分支")
    end
  end

  describe "检查合并状态 (3.2)" do
    test "asks the machine and cools down", ctx do
      deliver(ctx)
      Events.subscribe(Events.topic(:daemon, ctx.daemon.id))
      {:ok, view, _html} = open(ctx)

      view |> element("#task-local-branch-refresh") |> render_click()
      assert_receive {:daemon_config_changed}
      assert render(view) =~ "已请求 alice-mbp 重新检查，结果稍后自动出现"
      assert has_element?(view, "#task-local-branch-refresh[disabled]")

      send(view.pid, :local_branch_cooldown_over)
      refute has_element?(view, "#task-local-branch-refresh[disabled]")
      assert has_element?(view, "#task-local-branch-refresh")
    end

    test "unavailable while the machine is offline", ctx do
      deliver(ctx)
      ctx.local_repo |> Ecto.Changeset.change(status: "offline") |> Repo.update!()
      {:ok, view, _html} = open(ctx)

      assert has_element?(view, ~s(#task-local-branch-refresh[aria-disabled="true"]))
      assert has_element?(view, "#task-local-branch-refresh-reason", "机器离线或仓库不可用，恢复后会自动检查")
      assert has_element?(view, "#task-local-branch-status", "所在机器离线")
    end
  end

  describe "marking (3.3)" do
    defp open_mark(view), do: view |> element("#task-local-branch-mark") |> render_click()

    defp submit(view, note \\ ""),
      do: render_submit(view, "local_branch_mark", %{"local_merge" => %{"note" => note}})

    defp confirm_latest(view, sha),
      do: render_click(view, "local_branch_confirm_latest", %{"sha" => sha})

    defp new_delivery(ctx, sha) do
      ctx.task.id |> local_branch() |> set_local_branch(head_sha: sha, state: "open")
    end

    test "marking merged", ctx do
      deliver(ctx)
      {:ok, view, _html} = open(ctx)
      open_mark(view)

      assert open?(view, @panel)
      assert in_portal?(view, @panel, "#local-merge-panel-title", "标记为已合并 · #{ctx.task.ident}")
      assert in_portal?(view, @panel, "#local-merge-description [data-confirmed-sha]", "a1b2c3d")
      assert portal_attr(view, @panel, "#local-merge-note", "maxlength") == "2000"

      submit(view, "squash 合并")
      refute open?(view, @panel)
      assert render(view) =~ "已标记为已合并"
      assert has_element?(view, "#task-local-branch-state", "已合并")
      assert has_element?(view, "#task-local-branch-note", "squash 合并")
      assert branch_state(ctx) == "merged"
    end

    test "a new delivery while the panel is open", ctx do
      deliver(ctx)
      {:ok, view, _html} = open(ctx)
      open_mark(view)
      new_delivery(ctx, @b)
      notify(ctx)

      assert in_portal?(view, @panel, "#local-merge-head-changed", "有新的交付 b2c3d4e，你确认的是 a1b2c3d")
      assert in_portal?(view, @panel, "#local-merge-description [data-confirmed-sha]", "a1b2c3d")
      assert portal_attr(view, @panel, "#local-merge-confirm-latest", "phx-value-sha") == @b
      assert in_portal?(view, @panel, "#local-merge-confirm-latest", "改为确认 b2c3d4e")

      submit(view, "x")
      assert branch_state(ctx) == "open"
      assert open?(view, @panel)
    end

    test "a submit in flight when a new delivery arrives", ctx do
      deliver(ctx)
      {:ok, view, _html} = open(ctx)
      open_mark(view)
      render_change(view, "local_branch_mark_change", %{"local_merge" => %{"note" => "我的说明"}})

      # The notification is handled before the submit.
      new_delivery(ctx, @b)
      send(view.pid, {:local_branch_changed, ctx.task.ident})
      submit(view, "我的说明")

      assert branch_state(ctx) == "open"
      assert state(view).panel.confirmed_sha == @a
      assert state(view).panel.latest_sha == @b
      assert state(view).panel.note == "我的说明"
      assert in_portal?(view, @panel, "#local-merge-head-changed", "b2c3d4e")
    end

    test "confirming the new commit explicitly keeps the note", ctx do
      deliver(ctx)
      {:ok, view, _html} = open(ctx)
      open_mark(view)
      render_change(view, "local_branch_mark_change", %{"local_merge" => %{"note" => "squash"}})
      new_delivery(ctx, @b)
      notify(ctx)
      _ = render(view)

      confirm_latest(view, @b)
      refute in_portal?(view, @panel, "#local-merge-head-changed")
      assert in_portal?(view, @panel, "#local-merge-description [data-confirmed-sha]", "b2c3d4e")
      assert in_portal?(view, @panel, "#local-merge-note", "squash")

      submit(view, "squash")
      assert %{state: "merged", head_sha: @b, merge_note: "squash"} = local_branch(ctx.task.id)
    end

    test "a confirm click in flight when another delivery arrives", ctx do
      deliver(ctx)
      {:ok, view, _html} = open(ctx)
      open_mark(view)
      new_delivery(ctx, @b)
      notify(ctx)
      assert portal_attr(view, @panel, "#local-merge-confirm-latest", "phx-value-sha") == @b

      # C arrives before the click on the button rendered for B is handled.
      new_delivery(ctx, @c)
      send(view.pid, {:local_branch_changed, ctx.task.ident})
      confirm_latest(view, @b)

      assert state(view).panel.confirmed_sha == @b
      assert in_portal?(view, @panel, "#local-merge-head-changed", "有新的交付 c3d4e5f，你确认的是 b2c3d4e")
      assert portal_attr(view, @panel, "#local-merge-confirm-latest", "phx-value-sha") == @c

      submit(view)
      assert branch_state(ctx) == "open"

      confirm_latest(view, @c)
      submit(view)
      assert %{state: "merged", head_sha: @c} = local_branch(ctx.task.id)
    end

    test "after head_changed a submit without confirming is still refused", ctx do
      deliver(ctx)
      {:ok, view, _html} = open(ctx)
      open_mark(view)
      new_delivery(ctx, @b)

      submit(view)
      assert in_portal?(view, @panel, "#local-merge-head-changed", "b2c3d4e")
      submit(view)
      assert branch_state(ctx) == "open"
      assert state(view).panel.confirmed_sha == @a
    end

    test "a confirm event without a full SHA is ignored", ctx do
      deliver(ctx)
      {:ok, view, _html} = open(ctx)
      open_mark(view)

      confirm_latest(view, "b2c3d4e")
      confirm_latest(view, String.upcase(@b))
      assert state(view).panel.confirmed_sha == @a
    end

    test "a note over 2000 characters", ctx do
      deliver(ctx)
      {:ok, view, _html} = open(ctx)
      open_mark(view)
      submit(view, String.duplicate("长", 2001))

      assert in_portal?(view, @panel, "#local-merge-form", "说明最多 2000 字")
      assert branch_state(ctx) == "open"
    end

    test "marked by someone else meanwhile", ctx do
      deliver(ctx)
      {:ok, view, _html} = open(ctx)
      open_mark(view)
      {:ok, bobs} = LocalRepositories.mark_merged(ctx.bob_scope, ctx.task.ident, "bob 合并的")
      submit(view)

      refute open?(view, @panel)
      assert render(view) =~ "已经是已合并"

      assert has_element?(
               view,
               "#task-local-branch-merged [data-marked]",
               "#{bobs.merged_by.name} 标记为已合并"
             )
    end

    test "undoing a mark", ctx do
      deliver(ctx)
      {:ok, _} = LocalRepositories.mark_merged(ctx.alice_scope, ctx.task.ident)
      {:ok, view, _html} = open(ctx)

      view |> element("#task-local-branch-unmark") |> render_click()
      assert open?(view, "local-unmerge-confirm")
      assert in_portal?(view, "local-unmerge-confirm", "*", "依赖这个任务的任务将重新等待它合并")

      render_click(view, "local_branch_unmark", %{})
      assert render(view) =~ "已撤销已合并标记"
      assert has_element?(view, "#task-local-branch-state", "未合并")
      assert branch_state(ctx) == "open"
    end

    test "the undo dialog closes when someone else undid it", ctx do
      deliver(ctx)
      {:ok, _} = LocalRepositories.mark_merged(ctx.alice_scope, ctx.task.ident)
      {:ok, view, _html} = open(ctx)
      view |> element("#task-local-branch-unmark") |> render_click()

      {:ok, _} = LocalRepositories.mark_unmerged(ctx.bob_scope, ctx.task.ident)
      eventually(fn -> not state(view).unmark? end)
      refute open?(view, "local-unmerge-confirm")
    end

    # code-review-1 P2-2: a confirmation in flight after the dialog closed writes nothing.
    test "a late undo confirmation keeps a merge detected since", ctx do
      deliver(ctx)
      {:ok, _} = LocalRepositories.mark_merged(ctx.alice_scope, ctx.task.ident, "manual")
      {:ok, view, _html} = open(ctx)
      view |> element("#task-local-branch-unmark") |> render_click()
      assert open?(view, "local-unmerge-confirm")

      {:ok, _} = LocalRepositories.mark_unmerged(ctx.bob_scope, ctx.task.ident)

      ctx.task.id
      |> local_branch()
      |> set_local_branch(
        state: "merged",
        merged_at: DateTime.utc_now(:second),
        merged_by_id: nil
      )

      notify(ctx)
      _ = render(view)
      refute open?(view, "local-unmerge-confirm")

      render_click(view, "local_branch_unmark", %{})
      assert %{state: "merged", merged_by_id: nil} = local_branch(ctx.task.id)
      assert has_element?(view, "#task-local-branch-merged [data-detected]")
    end

    test "a detection between the page's check and the write is refused under the lock", ctx do
      deliver(ctx)
      {:ok, _} = LocalRepositories.mark_merged(ctx.alice_scope, ctx.task.ident, "manual")
      {:ok, view, _html} = open(ctx)
      view |> element("#task-local-branch-unmark") |> render_click()

      # Changed without a notification: the page still shows the person's mark.
      ctx.task.id |> local_branch() |> set_local_branch(merged_by_id: nil)
      render_click(view, "local_branch_unmark", %{})

      assert %{state: "merged", merged_by_id: nil} = local_branch(ctx.task.id)
      assert render(view) =~ "已由自动检测确认合并，不能撤销"
      assert has_element?(view, "#task-local-branch-merged [data-detected]")
    end

    test "an undo event without an open confirmation writes nothing", ctx do
      deliver(ctx)
      {:ok, _} = LocalRepositories.mark_merged(ctx.alice_scope, ctx.task.ident)
      {:ok, view, _html} = open(ctx)

      render_click(view, "local_branch_unmark", %{})
      assert branch_state(ctx) == "merged"
    end

    test "a merge detected by the machine cannot be undone", ctx do
      deliver(ctx, %{state: "merged", merged_at: DateTime.utc_now(:second)})
      {:ok, view, _html} = open(ctx)

      assert has_element?(view, "#task-local-branch-merged [data-detected]", "已检测到合并进 main")
      refute has_element?(view, "#task-local-branch-unmark")
      refute has_element?(view, "#task-local-branch-mark")
      refute has_element?(view, "#task-local-branch-refresh")
    end

    test "a viewer has no actions", ctx do
      deliver(ctx)
      {:ok, view, _html} = open(ctx, :viewer)

      assert has_element?(view, "#task-local-branch")
      refute has_element?(view, "#task-local-branch-refresh")
      refute has_element?(view, "#task-local-branch-mark")
      refute has_element?(view, "#task-local-branch-actions")

      render_click(view, "local_branch_open_mark", %{})
      assert state(view).panel == nil
    end
  end

  describe "assigning to another machine (3.5)" do
    defp choose(view, name),
      do: view |> element("#" <> Show.assignee_item_id(name)) |> render_click()

    defp elsewhere(ctx) do
      {bob_pc, _} =
        daemon_fixture(ctx.users.bob, %{name: "bob-pc", workspace_ids: [ctx.workspace.id]})

      repo =
        local_repository_fixture(ctx.workspace, bob_pc, %{name: "api", path: "/home/bob/api"})

      bind_local(ctx.project, repo)
    end

    test "the runtime is on another machine", ctx do
      elsewhere(ctx)
      {:ok, view, _html} = open(ctx)

      assert has_element?(
               view,
               ~s(##{Show.assignee_item_id("keel/dev")}[data-other-machine]),
               "不在 bob-pc 上"
             )

      choose(view, "keel/dev")
      assert open?(view, "assign-confirm")

      assert in_portal?(
               view,
               "assign-confirm",
               "#assign-confirm-other-machine",
               "这个项目的仓库 api 在 bob-pc 上，keel/dev 的运行时在 alice-mbp 上：运行会以『准备工作区』失败"
             )

      assert in_portal?(view, "assign-confirm", "button", "开始")
    end

    test "the same machine", ctx do
      {:ok, view, _html} = open(ctx)
      refute has_element?(view, "[data-other-machine]")

      choose(view, "keel/dev")
      assert open?(view, "assign-confirm")
      refute in_portal?(view, "assign-confirm", "#assign-confirm-other-machine")
    end

    test "the new task panel's start hint", ctx do
      elsewhere(ctx)

      {:ok, view, _html} =
        live(
          log_in_user(ctx.conn, ctx.alice),
          "/w/#{ctx.workspace.slug}/p/#{ctx.project.key}?panel=new"
        )

      view
      |> with_target("#new-task-panel")
      |> render_change("change", %{task: %{project: ctx.project.key, assignee: "keel/dev"}})

      assert in_portal?(
               view,
               "new-task-dialog",
               "#new-task-other-machine",
               "这个项目的仓库 api 在 bob-pc 上"
             )
    end
  end

  describe "live updates (3.6)" do
    test "a merge detected by the machine", ctx do
      deliver(ctx)
      {:ok, view, _html} = open(ctx, :bob)

      ctx.task.id
      |> local_branch()
      |> set_local_branch(state: "merged", merged_at: DateTime.utc_now(:second))

      notify(ctx)
      eventually(fn -> has_element?(view, "#task-local-branch-merged [data-detected]") end)
      assert has_element?(view, "#task-local-branch-state", "已合并")
    end

    test "a new delivery after a merge", ctx do
      deliver(ctx, %{state: "merged", merged_at: DateTime.utc_now(:second)})
      {:ok, view, _html} = open(ctx, :bob)

      ctx.task.id
      |> local_branch()
      |> set_local_branch(state: "open", merged_at: nil, head_sha: @b)

      notify(ctx)

      eventually(fn -> has_element?(view, "#task-local-branch-head", "b2c3d4e") end)
      assert has_element?(view, "#task-local-branch-state", "未合并")
    end

    test "the machine going offline", ctx do
      deliver(ctx)
      {:ok, view, _html} = open(ctx)
      assert has_element?(view, ~s(#task-local-branch-chip[data-status="online"]))

      {:ok, _} =
        Tx.run(fn -> {:ok, LocalRepositories.offline(ctx.daemon.id, [ctx.workspace.id])} end)

      eventually(fn -> has_element?(view, ~s(#task-local-branch-chip[data-status="offline"])) end)
      assert has_element?(view, "#task-local-branch-status", "所在机器离线")
    end
  end
end
