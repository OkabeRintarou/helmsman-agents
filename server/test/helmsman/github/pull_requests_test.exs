defmodule Helmsman.GitHub.PullRequestsTest do
  # add-pr-reconcile-merge 1.7, 1.8: re-verifying, merging now, retrying
  # (decisions 10, 11, 14), reading and notifications (decisions 17, 22),
  # and the reads of add-github-ui (domain request 1, R1–R3).
  use Helmsman.DataCase, async: true
  use Oban.Testing, repo: Helmsman.Repo

  import Helmsman.PullRequestFixtures
  import Helmsman.RunsFixtures

  alias Helmsman.{Events, FakeGitHub, Tasks}
  alias Helmsman.Feedback.Entry
  alias Helmsman.GitHub.{PullRequest, PullRequests}
  alias Helmsman.GitHub.Workers.ReconcilePR
  alias Helmsman.Runs.Run
  alias Helmsman.Tasks.TaskEvent

  setup do
    ctx = pr_fixture()
    fake = FakeGitHub.start()
    pushed_run(ctx, sha("c"), sha("0"))
    {:ok, _} = move(ctx.alice_scope, ctx.task, [:in_progress, :done, :verified])
    FakeGitHub.put_pull(fake, 1, %{head_ref: ctx.branch, head_sha: sha("c")})
    pr = pr_row(ctx, %{number: 1, head_sha: sha("c")})
    Repo.delete_all(Oban.Job)
    Map.merge(ctx, %{fake: fake, pr: pr})
  end

  defp set_pr(ctx, changes),
    do: Repo.update_all(where(PullRequest, id: ^ctx.pr.id), set: changes)

  # The review agent pushed `sha` after the verification; GitHub's head
  # follows; the pull request is stale.
  defp stale(ctx, sha) do
    pushed_run(ctx, sha, sha("c"))
    FakeGitHub.change_pull(ctx.fake, 1, head_sha: sha)
    set_pr(ctx, head_sha: sha, merge_status: :stale, merge_reason: :head_changed)
  end

  defp counts(ctx) do
    {Repo.aggregate(from(f in Entry, where: f.task_id == ^ctx.task.id), :count),
     Repo.aggregate(from(e in TaskEvent, where: e.task_id == ^ctx.task.id), :count)}
  end

  defp reconcile(ctx), do: perform_job(ReconcilePR, %{task_id: ctx.task.id})

  describe "reverify/3" do
    test "at the current commit (按当前提交重新验收)", ctx do
      stale(ctx, sha("d"))
      Events.subscribe(Events.topic(:task, ctx.task.id))

      assert {:ok, view} = PullRequests.reverify(ctx.alice_scope, ctx.task.ident)
      assert view.verified_sha == sha("d")

      v = latest_verification(ctx.task)

      assert %TaskEvent{from_status: :verified, to_status: :verified, verified_sha: verified} = v
      assert verified == sha("d")
      assert v.actor_id == ctx.alice_scope.actor.id

      entry = Repo.get!(Entry, v.feedback_id)
      assert entry.kind == :review and entry.content == "Re-verified at ddddddd."
      assert_enqueued(worker: ReconcilePR, args: %{task_id: ctx.task.id})

      assert_receive {:task_transitioned,
                      %{event: %{from: "verified", to: "verified", verified_sha: ^verified}}}

      # Then judged by d.
      FakeGitHub.update(
        ctx.fake,
        &%{&1 | checks: %{sha("d") => [FakeGitHub.check_run("t", "success")]}}
      )

      assert :ok = reconcile(ctx)
      assert FakeGitHub.get(ctx.fake).last_merge["sha"] == sha("d")
    end

    test "a verification from before this feature (上线前的旧验收)", ctx do
      Repo.update_all(where(TaskEvent, task_id: ^ctx.task.id), set: [verified_sha: nil])
      set_pr(ctx, merge_status: :blocked, merge_reason: :verified_sha_missing)

      assert {:ok, %{verified_sha: verified}} =
               PullRequests.reverify(ctx.alice_scope, ctx.task.ident)

      assert verified == sha("c")
      assert latest_verification(ctx.task).verified_sha == sha("c")
    end

    test "other blocks cannot be re-verified (其他阻断不能重新验收)", ctx do
      set_pr(ctx, merge_status: :blocked, merge_reason: :not_independent)
      before = counts(ctx)

      assert PullRequests.reverify(ctx.alice_scope, ctx.task.ident) == {:error, :not_reverifiable}
      assert counts(ctx) == before
    end

    test "a head pushed by hand (手动推过的提交不能重新验收)", ctx do
      FakeGitHub.change_pull(ctx.fake, 1, head_sha: sha("f"))
      set_pr(ctx, merge_status: :stale, merge_reason: :head_changed)
      before = counts(ctx)

      assert PullRequests.reverify(ctx.alice_scope, ctx.task.ident) ==
               {:error, :not_pushed_by_run}

      assert counts(ctx) == before

      # Also for a verification without a recorded commit.
      set_pr(ctx, merge_status: :blocked, merge_reason: :verified_sha_missing)

      assert PullRequests.reverify(ctx.alice_scope, ctx.task.ident) ==
               {:error, :not_pushed_by_run}
    end

    test "the head moved after the confirmation (确认之后头部变了)", ctx do
      stale(ctx, sha("d"))
      FakeGitHub.change_pull(ctx.fake, 1, head_sha: sha("e"))
      pushed_run(ctx, sha("e"), sha("d"))
      before = counts(ctx)

      assert PullRequests.reverify(ctx.alice_scope, ctx.task.ident, expected_head_sha: sha("d")) ==
               {:error, {:head_changed, sha("e")}}

      assert counts(ctx) == before
    end

    test "an active run, a task not verified", ctx do
      stale(ctx, sha("d"))
      run = pushed_run(ctx, sha("d"), sha("c"), status: :running)

      assert {:error, {:run_active, %{id: id}}} =
               PullRequests.reverify(ctx.alice_scope, ctx.task.ident)

      assert id == run.id

      Repo.update_all(where(Run, id: ^run.id), set: [status: :succeeded])
      {:ok, _} = Tasks.transition(ctx.alice_scope, ctx.task.ident, :in_progress)

      assert PullRequests.reverify(ctx.alice_scope, ctx.task.ident) ==
               {:error, {:invalid_status, :in_progress}}
    end

    test "viewers and agents are refused", ctx do
      stale(ctx, sha("d"))
      {_user, viewer} = member_scope_fixture(ctx.workspace, :viewer)
      assert PullRequests.reverify(viewer, ctx.task.ident) == {:error, :forbidden}

      assert PullRequests.reverify(%{ctx.alice_scope | actor: ctx.agent}, ctx.task.ident) ==
               {:error, :forbidden}
    end
  end

  describe "merge_now/3" do
    setup ctx do
      # keel/dev verified it itself: not independent.
      v = latest_verification(ctx.task)
      Repo.update_all(where(TaskEvent, id: ^v.id), set: [actor_id: ctx.agent.id])

      FakeGitHub.update(
        ctx.fake,
        &%{&1 | checks: %{sha("c") => [FakeGitHub.check_run("t", "success")]}}
      )

      :ok
    end

    test "an owner skips the independence check (owner 跳过独立性)", ctx do
      assert :ok = reconcile(ctx)
      assert %PullRequest{merge_reason: :not_independent} = Repo.get!(PullRequest, ctx.pr.id)

      assert {:ok, view} =
               PullRequests.merge_now(ctx.alice_scope, ctx.task.ident,
                 skip_independence: "hotfix"
               )

      assert %{by: %{name: name, kind: "human"}, skip_independence?: true} = view.merge_request
      assert name == ctx.alice_scope.actor.name

      [comment] =
        Repo.all(from(f in Entry, where: f.task_id == ^ctx.task.id and f.kind == :comment))

      assert comment.author_id == ctx.system.id
      assert comment.content == "#{name} asked to merge without the independence check: hotfix"
      assert_enqueued(worker: ReconcilePR, args: %{task_id: ctx.task.id})

      assert :ok = reconcile(ctx)
      assert FakeGitHub.get(ctx.fake).last_merge["sha"] == sha("c")
    end

    test "an admin asking to skip is refused (非 owner 跳过独立性)", ctx do
      {_bob, bob} = member_scope_fixture(ctx.workspace, :admin)
      before = counts(ctx)

      assert PullRequests.merge_now(bob, ctx.task.ident, skip_independence: "hotfix") ==
               {:error, :forbidden}

      assert counts(ctx) == before
      assert Repo.get!(PullRequest, ctx.pr.id).merge_request == nil
    end

    test "a running agent is refused (Agent 不能操作)", ctx do
      run =
        run_fixture(ctx.agent, %{
          task_id: ctx.task.id,
          status: :running,
          capabilities: Run.capabilities()
        })

      {scope, _token} = run_scope_fixture(run)
      assert PullRequests.merge_now(scope, ctx.task.ident) == {:error, :forbidden}
    end

    test "a request lets a manual policy through, for its verification only", ctx do
      v = latest_verification(ctx.task)
      Repo.update_all(where(TaskEvent, id: ^v.id), set: [actor_id: ctx.alice_scope.actor.id])

      Repo.update_all(where(Helmsman.Projects.Project, id: ^ctx.project.id),
        set: [merge_policy: "manual"]
      )

      assert :ok = reconcile(ctx)
      assert %PullRequest{merge_reason: :policy_manual} = Repo.get!(PullRequest, ctx.pr.id)

      {_user, member} = member_scope_fixture(ctx.workspace, :member)

      assert {:ok, %{merge_request: %{skip_independence?: false}}} =
               PullRequests.merge_now(member, ctx.task.ident)

      assert :ok = reconcile(ctx)
      assert FakeGitHub.get(ctx.fake).last_merge
    end

    test "invalid reasons and states", ctx do
      assert PullRequests.merge_now(ctx.alice_scope, ctx.task.ident, skip_independence: " ") ==
               {:error, :invalid_reason}

      assert PullRequests.merge_now(ctx.alice_scope, ctx.task.ident,
               skip_independence: String.duplicate("x", 1001)
             ) ==
               {:error, :invalid_reason}

      set_pr(ctx, state: :closed)
      assert PullRequests.merge_now(ctx.alice_scope, ctx.task.ident) == {:error, :no_pull_request}
    end
  end

  test "retry/2 restarts the CI wait", ctx do
    set_pr(ctx,
      merge_status: :blocked,
      merge_reason: :ci_timeout,
      waiting_since: DateTime.add(DateTime.utc_now(), -7 * 3600)
    )

    assert {:ok, view} = PullRequests.retry(ctx.alice_scope, ctx.task.ident)
    assert view.waiting_since == nil
    assert Repo.get!(PullRequest, ctx.pr.id).waiting_since == nil
    assert_enqueued(worker: ReconcilePR, args: %{task_id: ctx.task.id})

    {_user, viewer} = member_scope_fixture(ctx.workspace, :viewer)
    assert PullRequests.retry(viewer, ctx.task.ident) == {:error, :forbidden}
  end

  describe "get/2 (PR 状态的读取与通知)" do
    test "a member reads a stale pull request (读取)", ctx do
      stale(ctx, sha("d"))
      {_carol, carol} = member_scope_fixture(ctx.workspace, :member)

      assert {:ok, view} = PullRequests.get(carol, ctx.task.ident)

      assert %{
               number: 1,
               url: "https://github.com/acme/app/pull/1",
               repository: %{full_name: "acme/app"},
               state: "open",
               base_branch: "main",
               checks_state: "none",
               checks: nil,
               merge_status: "stale",
               merge_reason: "head_changed",
               auto_reopen_count: 0,
               max_auto_reopens: 3,
               merge_request: nil,
               waiting_since: nil,
               can: %{reverify: true, merge_now: true, skip_independence: false, retry: true}
             } = view

      assert view.head_sha == sha("d") and view.verified_sha == sha("c")
      assert view.branch == ctx.branch

      assert {:ok, %{can: %{skip_independence: true}}} =
               PullRequests.get(ctx.alice_scope, ctx.task.ident)

      {_v, viewer} = member_scope_fixture(ctx.workspace, :viewer)

      assert {:ok, %{can: %{reverify: false, merge_now: false, retry: false}}} =
               PullRequests.get(viewer, ctx.task.ident)
    end

    test "checks detail only for the head it was read for (decision 22)", ctx do
      checks = %{
        "head_sha" => sha("c"),
        "total" => 2,
        "passed" => 1,
        "pending" => 0,
        "failed" => ["lint"]
      }

      set_pr(ctx, checks: checks, checks_state: :failure)

      assert {:ok, %{checks: view}} = PullRequests.get(ctx.alice_scope, ctx.task.ident)
      assert view == %{head_sha: sha("c"), total: 2, passed: 1, pending: 0, failed: ["lint"]}

      set_pr(ctx, head_sha: sha("d"))
      assert {:ok, %{checks: nil}} = PullRequests.get(ctx.alice_scope, ctx.task.ident)
    end

    test "nil without a pull request; merged?/1", ctx do
      refute PullRequests.merged?(ctx.task.id)
      set_pr(ctx, state: :merged)
      assert PullRequests.merged?(ctx.task.id)

      Repo.delete_all(where(PullRequest, id: ^ctx.pr.id))
      assert PullRequests.get(ctx.alice_scope, ctx.task.ident) == {:ok, nil}
      assert PullRequests.get(ctx.alice_scope, "NOPE-1") == {:error, :not_found}
    end

    test "{:pull_request_changed, ident} on a change only; after_merge", ctx do
      Events.subscribe(Events.topic(:task, ctx.task.id))
      ident = ctx.task.ident
      test = self()
      handler = "after-merge-#{inspect(test)}"

      :telemetry.attach(
        handler,
        [:helmsman, :pull_requests, :after_merge],
        fn _e, _m, meta, _ -> send(test, {:after_merge, meta.task_id}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      FakeGitHub.update(
        ctx.fake,
        &%{&1 | checks: %{sha("c") => [FakeGitHub.check_run("t", nil)]}}
      )

      assert :ok = reconcile(ctx)
      assert_receive {:pull_request_changed, ^ident}

      # The same facts again: no change, no message.
      Repo.update_all(where(PullRequest, id: ^ctx.pr.id),
        set: [waiting_since: Repo.get!(PullRequest, ctx.pr.id).waiting_since]
      )

      assert :ok = reconcile(ctx)
      refute_receive {:pull_request_changed, _}

      FakeGitHub.change_pull(ctx.fake, 1,
        merged: true,
        state: "closed",
        merge_commit_sha: sha("e")
      )

      assert :ok = reconcile(ctx)
      assert_receive {:pull_request_changed, ^ident}
      task_id = ctx.task.id
      assert_receive {:after_merge, ^task_id}
    end
  end

  describe "verify_preview/2 (add-github-ui R3)" do
    test "the outcome for the scope's identity", ctx do
      {_bob, bob} = member_scope_fixture(ctx.workspace, :member)

      assert {:ok,
              %{
                verified_sha: verified,
                checks_state: "none",
                base_branch: "main",
                outcome: "auto_merge"
              }} =
               PullRequests.verify_preview(bob, ctx.task.ident)

      assert verified == sha("c")

      # keel/dev pushed it: not independent.
      agent_scope = %{ctx.alice_scope | actor: ctx.agent}

      assert {:ok, %{outcome: "not_independent"}} =
               PullRequests.verify_preview(agent_scope, ctx.task.ident)

      Repo.update_all(where(Helmsman.Projects.Project, id: ^ctx.project.id),
        set: [merge_policy: "on_verified_human"]
      )

      assert {:ok, %{outcome: "agent_verified"}} =
               PullRequests.verify_preview(agent_scope, ctx.task.ident)

      Repo.update_all(where(Helmsman.Projects.Project, id: ^ctx.project.id),
        set: [merge_policy: "manual"]
      )

      assert {:ok, %{outcome: "policy_manual"}} = PullRequests.verify_preview(bob, ctx.task.ident)
    end

    test "no commit, unavailable repository, no repository", ctx do
      {_bob, bob} = member_scope_fixture(ctx.workspace, :member)

      Repo.update_all(where(Run, task_id: ^ctx.task.id),
        set: [push_status: :none, base_sha: nil, head_sha: nil, pushed_at: nil]
      )

      assert {:ok, %{verified_sha: nil, outcome: "no_commit"}} =
               PullRequests.verify_preview(bob, ctx.task.ident)

      Repo.update_all(where(Helmsman.GitHub.Repository, id: ^ctx.repository.id),
        set: [archived: true]
      )

      assert {:ok, %{outcome: "repository_unavailable"}} =
               PullRequests.verify_preview(bob, ctx.task.ident)

      Repo.update_all(where(Helmsman.Projects.Project, id: ^ctx.project.id),
        set: [repository_id: nil]
      )

      assert PullRequests.verify_preview(bob, ctx.task.ident) == {:ok, nil}
      assert FakeGitHub.requests(ctx.fake) == []
    end
  end

  test "history views carry verified_sha (add-github-ui R2)", ctx do
    {:ok, task} = Tasks.get(ctx.alice_scope, ctx.task.ident)
    assert List.last(Tasks.detail(task).history).verified_sha == sha("c")
  end
end
