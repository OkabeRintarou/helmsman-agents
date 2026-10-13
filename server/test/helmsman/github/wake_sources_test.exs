defmodule Helmsman.GitHub.WakeSourcesTest do
  # add-pr-reconcile-merge 1.5: what wakes a task's reconciliation
  # (decision 4).
  use Helmsman.DataCase, async: true
  use Oban.Testing, repo: Helmsman.Repo

  import Helmsman.GitHubFixtures
  import Helmsman.GitRunFixtures
  import Helmsman.ProjectsFixtures
  import Helmsman.RunsFixtures

  alias Helmsman.GitHub.PullRequest
  alias Helmsman.GitHub.Workers.{ReconcilePR, ReconcileSweep}
  alias Helmsman.{Projects, Runs, Tasks}
  alias Helmsman.Projects.Project
  alias HelmsmanProtocol.Report

  setup do
    ctx = git_run_fixture()
    Repo.delete_all(Oban.Job)
    ctx
  end

  defp woken?(task), do: all_enqueued(worker: ReconcilePR, args: %{task_id: task.id}) != []

  defp unbind(project),
    do: Repo.update_all(where(Project, id: ^project.id), set: [repository_id: nil])

  defp pr_row(ctx, task, attrs) do
    Repo.insert!(
      struct!(
        %PullRequest{
          workspace_id: ctx.workspace.id,
          task_id: task.id,
          repository_id: ctx.repository.id,
          number: System.unique_integer([:positive]),
          node_id: "PR_x",
          url: "https://github.com/acme/app/pull/1",
          branch: "b",
          base_branch: "main",
          state: :open
        },
        attrs
      )
    )
  end

  describe "transitions" do
    test "a task of a bound project", ctx do
      {:ok, _} = Tasks.transition(ctx.alice_scope, ctx.task.ident, :in_progress)
      assert_enqueued(worker: ReconcilePR, args: %{task_id: ctx.task.id})
    end

    test "not without a repository", ctx do
      unbind(ctx.project)
      {:ok, _} = Tasks.transition(ctx.alice_scope, ctx.task.ident, :in_progress)
      refute woken?(ctx.task)
    end
  end

  test "a recorded push", ctx do
    {:ok, report} =
      Report.Pushed.new(%{
        run_id: ctx.run.id,
        branch: ctx.branch,
        base_sha: sha("0"),
        head_sha: sha("a"),
        commits: [],
        rescue_branch: nil
      })

    assert :ok = Runs.pushed(ctx.dctx, report)
    assert_enqueued(worker: ReconcilePR, args: %{task_id: ctx.task.id})
  end

  describe "runs ending" do
    test "a running run finishing", ctx do
      {:ok, report} = Report.Finished.new(%{run_id: ctx.run.id, status: :succeeded})
      assert :ok = Runs.finish(ctx.dctx, report)
      assert_enqueued(worker: ReconcilePR, args: %{task_id: ctx.task.id})
    end

    test "a claimed run whose lease expired (the sweep)", ctx do
      set_run(ctx.run,
        status: :claimed,
        started_at: nil,
        claimed_at: DateTime.add(DateTime.utc_now(), -3600)
      )

      Repo.update_all(where(Helmsman.Daemons.Daemon, id: ^ctx.daemon.id),
        set: [last_seen_at: DateTime.utc_now()]
      )

      assert :ok = perform_job(Helmsman.Runs.Workers.Sweep, %{})
      assert Repo.get!(Runs.Run, ctx.run.id).status == :failed
      assert_enqueued(worker: ReconcilePR, args: %{task_id: ctx.task.id})
    end

    test "a queued run cancelled directly does not wake", ctx do
      queued = run_fixture(ctx.agent, %{task_id: ctx.task.id})
      set_run(ctx.run, status: :succeeded, finished_at: DateTime.utc_now())
      Repo.delete_all(Oban.Job)

      assert {:ok, _} = Runs.cancel(ctx.alice_scope, queued.id)
      refute woken?(ctx.task)
    end

    test "not without a repository", ctx do
      unbind(ctx.project)
      {:ok, report} = Report.Finished.new(%{run_id: ctx.run.id, status: :succeeded})
      assert :ok = Runs.finish(ctx.dctx, report)
      refute woken?(ctx.task)
    end
  end

  test "project settings: verified tasks with open pull requests", ctx do
    verified = task_fixture(ctx.alice_scope, ctx.project.key)
    open_only = task_fixture(ctx.alice_scope, ctx.project.key)
    Repo.update_all(where(Tasks.Task, id: ^verified.id), set: [status: :verified])
    pr_row(ctx, verified, %{})
    pr_row(ctx, open_only, %{})
    Repo.delete_all(Oban.Job)

    assert {:ok, _} =
             Projects.update_github_settings(ctx.alice_scope, ctx.project.key, %{
               merge_policy: "manual"
             })

    assert_enqueued(worker: ReconcilePR, args: %{task_id: verified.id})
    refute woken?(open_only)

    # A change of other settings wakes nothing.
    Repo.delete_all(Oban.Job)

    assert {:ok, _} =
             Projects.update_github_settings(ctx.alice_scope, ctx.project.key, %{
               merge_method: "rebase"
             })

    refute woken?(verified)
  end

  describe "the sweep" do
    setup ctx do
      set_run(ctx.run, status: :succeeded, finished_at: DateTime.utc_now())
      task = fn -> task_fixture(ctx.alice_scope, ctx.project.key) end
      status = fn t, s -> Repo.update_all(where(Tasks.Task, id: ^t.id), set: [status: s]) end
      %{new_task: task, set_status: status}
    end

    test "picks the tasks of decision 4, by reconciliation time", ctx do
      verified = ctx.new_task.()
      ctx.set_status.(verified, :verified)
      pr_row(ctx, verified, %{reconciled_at: DateTime.add(DateTime.utc_now(), -60)})

      waiting = ctx.new_task.()
      pr_row(ctx, waiting, %{merge_status: :waiting, merge_reason: :run_active})

      # Any status: a pull request merged or closed on GitHub without a
      # webhook is only noticed by the sweep (M6 acceptance).
      in_progress = ctx.new_task.()
      pr_row(ctx, in_progress, %{})

      done = ctx.new_task.()
      ctx.set_status.(done, :done)
      pr_row(ctx, done, %{state: :draft, reconciled_at: DateTime.add(DateTime.utc_now(), -30)})

      closed = ctx.new_task.()
      ctx.set_status.(closed, :done)
      pr_row(ctx, closed, %{state: :closed})

      merged = ctx.new_task.()
      ctx.set_status.(merged, :verified)
      pr_row(ctx, merged, %{state: :merged})

      # A recent push without an open pull request (ctx.task), an old one.
      set_run(ctx.run,
        push_status: :pushed,
        base_sha: sha("0"),
        head_sha: sha("a"),
        pushed_at: DateTime.utc_now()
      )

      old = ctx.new_task.()

      claimed_git_run(Map.put(ctx, :task, old), %{
        status: :succeeded,
        push_status: :pushed,
        base_sha: sha("0"),
        head_sha: sha("b"),
        pushed_at: DateTime.add(DateTime.utc_now(), -8 * 86_400)
      })

      # A push to the repository the project was bound to before.
      other = repository_fixture(ctx.installation, %{owner: "acme", name: "other"})
      moved = ctx.new_task.()

      claimed_git_run(Map.put(ctx, :task, moved), %{
        status: :succeeded,
        repository_id: other.id,
        push_status: :pushed,
        base_sha: sha("0"),
        head_sha: sha("c"),
        pushed_at: DateTime.utc_now()
      })

      due = ReconcileSweep.due()

      assert Enum.sort(due) ==
               Enum.sort([verified.id, waiting.id, in_progress.id, done.id, ctx.task.id])

      # Never reconciled first, then the longest ago.
      assert Enum.take(due, -2) == [verified.id, done.id]
      assert ReconcileSweep.due(1) |> length() == 1

      assert :ok = perform_job(ReconcileSweep, %{})
      for t <- [verified, waiting, in_progress, done, ctx.task], do: assert(woken?(t))
      refute woken?(merged)
      refute woken?(closed)
    end
  end
end
