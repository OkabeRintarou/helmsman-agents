defmodule Helmsman.Dispatch.ReleaseDependentsTest do
  # add-dependency-dispatch 1.6: the re-check registered in the
  # transaction of a change made without the graph lock (decision 6), and
  # task-links「PR 合并通知依赖方」.
  use Helmsman.DataCase, async: true
  use Oban.Testing, repo: Helmsman.Repo

  import Helmsman.DependencyFixtures
  import Helmsman.GitRunFixtures, only: [git_run_fixture: 0]
  import Helmsman.LocalRepositoriesFixtures
  import Helmsman.ProjectsFixtures
  import Helmsman.PullRequestFixtures
  import Helmsman.RunsFixtures

  alias Helmsman.Dispatch.Dependencies
  alias Helmsman.Dispatch.Workers.ReleaseDependents
  alias Helmsman.Events
  alias Helmsman.GitHub.PullRequests.Reconcile
  alias Helmsman.{Links, LocalRepositories, Runs}
  alias Helmsman.Runs.Lifecycle
  alias Helmsman.{Tasks, Tx}
  alias HelmsmanProtocol.Report

  @worker "Helmsman.Dispatch.Workers.ReleaseDependents"

  defp jobs(task_id, states \\ ["available"]) do
    Repo.all(
      from(j in Oban.Job,
        where:
          j.worker == @worker and j.state in ^states and
            fragment("(?->>'task_id')::bigint = ?", j.args, ^task_id)
      )
    )
  end

  defp drain, do: Oban.drain_queue(queue: :default)

  defp clear_jobs, do: Repo.delete_all(from(j in Oban.Job, where: j.worker == @worker))

  # Runs `fun` inside a transaction that is then rolled back.
  defp rolled_back(fun) do
    assert {:error, :rolled_back} =
             Tx.run(fn ->
               fun.()
               {:error, :rolled_back}
             end)
  end

  # A dependent of `prereq` assigned to keel/dev: its deferred run.
  defp deferred_dependent(ctx, prereq) do
    task = task_fixture(ctx.alice_scope, ctx.project.key)
    {:ok, _} = Links.add(ctx.alice_scope, task.ident, prereq.ident, "depends_on")

    {:ok, %{dispatch: [%{result: :deferred}]}} =
      Tasks.update(ctx.alice_scope, task.ident, %{assignee: "keel/dev"})

    [run] = runs_in(task, :deferred)
    {task, run}
  end

  defp merge_pr(ctx, row, head) do
    {:ok, _} =
      Tx.run(fn ->
        {:ok,
         Reconcile.update_row(
           row,
           [state: :merged, merged_at: DateTime.utc_now(), merged_sha: head, included_sha: head],
           ctx.task
         )}
      end)
  end

  describe "scenarios" do
    test "PR 合并后开工, and the dependent is notified (task-links)" do
      ctx = pr_fixture()
      pushed_run(ctx, sha("c"), sha("0"))
      {web2, deferred} = deferred_dependent(ctx, ctx.task)
      {:ok, _} = move(ctx.alice_scope, ctx.task, [:in_progress, :done, :verified])
      assert run_status(deferred) == :deferred
      assert Links.waiting_for(ctx.task) == :merge

      row = pr_row(ctx, %{number: 1, head_sha: sha("c")})
      clear_jobs()
      merge_pr(ctx, row, sha("c"))
      assert_enqueued(worker: ReleaseDependents, args: %{task_id: ctx.task.id})
      assert run_status(deferred) == :deferred

      Events.subscribe(Events.topic(:project, web2.project_id))
      Events.subscribe(Events.topic(:task, web2.id))
      ident = web2.ident
      assert %{success: 1} = drain()

      assert run_status(deferred) == :queued
      assert_receive {:task_updated, %{id: ^ident, blocked: false}}
      assert_receive {:links_changed, ^ident}
    end

    test "置 DONE 的运行结束" do
      ctx = dependency_fixture()
      {:ok, _} = Tasks.transition(ctx.alice_scope, ctx.bos1.ident, "in_progress")
      {:ok, _} = Tasks.update(ctx.alice_scope, ctx.web2.ident, %{assignee: "keel/dev"})
      [deferred] = runs_in(ctx.web2, :deferred)

      run =
        run_fixture(ctx.agent, %{
          task_id: ctx.bos1.id,
          status: :running,
          capabilities: ["read", "write_task"]
        })

      {scope, _token} = run_scope_fixture(run)

      {:ok, _} = Tasks.transition(scope, ctx.bos1.ident, "done")
      assert run_status(deferred) == :deferred

      {:ok, _} = Tx.run(fn -> {:ok, Lifecycle.end!(run, :succeeded)} end)
      assert_enqueued(worker: ReleaseDependents, args: %{task_id: ctx.bos1.id})
      drain()
      assert run_status(deferred) == :queued
    end

    test "Epic 的步骤合并" do
      ctx = pr_fixture()
      epic = task_fixture(ctx.alice_scope, ctx.project.key, %{kind: "epic"})
      {:ok, _} = Tasks.update(ctx.alice_scope, ctx.task.ident, %{epic: epic.ident})
      pushed_run(ctx, sha("c"), sha("0"))
      {_web2, deferred} = deferred_dependent(ctx, epic)
      {:ok, _} = move(ctx.alice_scope, ctx.task, [:in_progress, :done, :verified])

      assert Repo.reload!(epic).status == :done
      assert Links.waiting_for(epic) == :steps
      assert run_status(deferred) == :deferred

      row = pr_row(ctx, %{number: 1, head_sha: sha("c")})
      merge_pr(ctx, row, sha("c"))
      drain()
      assert Links.waiting_for(epic) == nil
      assert run_status(deferred) == :queued
    end
  end

  describe "call sites (enqueued with the change, not on rollback)" do
    test "a run ends (Runs.after_terminal/1)" do
      ctx = dependency_fixture()
      run = run_fixture(ctx.agent, %{task_id: ctx.bos1.id, status: :running})

      rolled_back(fn -> Lifecycle.end!(run, :succeeded) end)
      assert jobs(ctx.bos1.id) == []

      {:ok, _} = Tx.run(fn -> {:ok, Lifecycle.end!(run, :failed)} end)
      assert_enqueued(worker: ReleaseDependents, args: %{task_id: ctx.bos1.id})
    end

    test "a run is claimed" do
      ctx = dependency_fixture()
      run_fixture(ctx.agent, %{task_id: ctx.bos1.id})
      assert {:ok, [_]} = Runs.claim(daemon_ctx(daemon_of(ctx.agent)), "http://localhost:4000")
      assert_enqueued(worker: ReleaseDependents, args: %{task_id: ctx.bos1.id})
    end

    test "a push is recorded (Runs.after_push/1)" do
      ctx = git_run_fixture()

      report = %Report.Pushed{
        run_id: ctx.run.id,
        branch: ctx.branch,
        base_sha: sha("0"),
        head_sha: sha("a"),
        commits: [%Report.Pushed.Commit{sha: sha("a"), subject: "Work"}],
        rescue_branch: nil
      }

      rolled_back(fn -> :ok = Runs.pushed(ctx.dctx, report) end)
      assert jobs(ctx.task.id) == []

      assert :ok = Runs.pushed(ctx.dctx, report)
      assert_enqueued(worker: ReleaseDependents, args: %{task_id: ctx.task.id})
    end

    test "a pull request merged first, or a new included_sha" do
      ctx = pr_fixture()
      row = pr_row(ctx, %{number: 1, head_sha: sha("c")})

      rolled_back(fn ->
        Reconcile.update_row(row, [state: :merged, merged_at: DateTime.utc_now()], ctx.task)
      end)

      assert jobs(ctx.task.id) == []

      {:ok, _} =
        Tx.run(fn ->
          {:ok, Reconcile.update_row(row, [included_sha: sha("c")], ctx.task)}
        end)

      assert [_] = jobs(ctx.task.id)
    end

    test "a local branch merged (detected or marked) or unmarked" do
      ctx = local_run_fixture()
      task_local_branch_fixture(ctx.task, ctx.local_repo, %{head_sha: sha("c")})

      rolled_back(fn ->
        {:ok, _} = LocalRepositories.mark_merged(ctx.alice_scope, ctx.task.ident)
      end)

      assert jobs(ctx.task.id) == []

      {:ok, _} = LocalRepositories.mark_merged(ctx.alice_scope, ctx.task.ident)
      assert [_] = jobs(ctx.task.id)
      clear_jobs()

      rolled_back(fn ->
        {:ok, _} = LocalRepositories.mark_unmerged(ctx.alice_scope, ctx.task.ident)
      end)

      assert jobs(ctx.task.id) == []

      {:ok, _} = LocalRepositories.mark_unmerged(ctx.alice_scope, ctx.task.ident)
      assert [_] = jobs(ctx.task.id)
      clear_jobs()

      status = %Report.RepoStatus{
        workspace_id: ctx.workspace.id,
        name: "app",
        results: [%Report.RepoStatus.Result{branch: ctx.branch, head_sha: sha("c"), merged: :yes}]
      }

      assert :ok = LocalRepositories.apply_status(ctx.dctx, status)
      assert [_] = jobs(ctx.task.id)
    end

    test "a step attached to or detached from an epic: both epics" do
      ctx = dispatch_fixture()
      [a, b] = for _ <- 1..2, do: task_fixture(ctx.alice_scope, ctx.project.key, %{kind: "epic"})
      task = task_fixture(ctx.alice_scope, ctx.project.key)
      clear_jobs()

      rolled_back(fn ->
        {:ok, _} = Tasks.update(ctx.alice_scope, task.ident, %{epic: a.ident})
      end)

      assert jobs(a.id) == []

      {:ok, _} = Tasks.update(ctx.alice_scope, task.ident, %{epic: a.ident})
      assert [_] = jobs(a.id)
      clear_jobs()

      {:ok, _} = Tasks.update(ctx.alice_scope, task.ident, %{epic: b.ident})
      assert {[_], [_]} = {jobs(a.id), jobs(b.id)}
      clear_jobs()

      {:ok, _} = Tasks.update(ctx.alice_scope, task.ident, %{epic: ""})
      assert [_] = jobs(b.id)

      {:ok, step} = Tasks.create(ctx.alice_scope, ctx.project.key, %{title: "S", epic: a.ident})
      assert step.epic_id == a.id
      assert [_] = jobs(a.id)
    end
  end

  test "three changes of one task: one job to run" do
    ctx = dependency_fixture()

    for _ <- 1..3,
        do: {:ok, :ok} = Tx.run(fn -> {:ok, Dependencies.changed(ctx.bos1.id)} end)

    assert [_] = jobs(ctx.bos1.id)
  end

  test "an executing job does not stop the next change from being queued" do
    ctx = dependency_fixture()
    {:ok, :ok} = Tx.run(fn -> {:ok, Dependencies.changed(ctx.bos1.id)} end)
    Repo.update_all(from(j in Oban.Job, where: j.worker == @worker), set: [state: "executing"])
    {:ok, :ok} = Tx.run(fn -> {:ok, Dependencies.changed(ctx.bos1.id)} end)
    assert [_] = jobs(ctx.bos1.id)
    assert [_] = jobs(ctx.bos1.id, ["executing"])
  end
end
