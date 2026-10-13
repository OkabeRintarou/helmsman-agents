defmodule Helmsman.GitHub.Workers.ReconcilePRTest do
  # add-pr-reconcile-merge 1.4: the reconciliation against a fake GitHub
  # (Req.Test; bodies from test/support/fixtures/github): pull-requests
  # "PR 对账", "PR 的目标状态", "自动合并的前提", "合并与合并后清理".
  use Helmsman.DataCase, async: true
  use Oban.Testing, repo: Helmsman.Repo

  import Helmsman.GitHubFixtures
  import Helmsman.PullRequestFixtures

  alias Helmsman.{FakeGitHub, Tasks}
  alias Helmsman.Feedback.Entry
  alias Helmsman.GitHub.{PullRequest, PullRequests}
  alias Helmsman.GitHub.PullRequests.Reconcile
  alias Helmsman.GitHub.Workers.{ReconcilePR, ReconcileSweep}
  alias Helmsman.Tasks.Task

  setup do
    ctx = pr_fixture()
    Map.put(ctx, :fake, FakeGitHub.start())
  end

  defp reconcile(ctx), do: perform_job(ReconcilePR, %{task_id: ctx.task.id})

  # A run of the task pushed `head` on `base`: the record and the branch.
  defp push!(ctx, head, base, attrs \\ %{}) do
    run = pushed_run(ctx, head, base, attrs)

    unless attrs[:rescue_branch] do
      FakeGitHub.update(ctx.fake, &%{&1 | refs: Map.put(&1.refs, ctx.branch, head)})

      for {n, %{head_ref: ref, state: "open"}} <- FakeGitHub.get(ctx.fake).pulls,
          ref == ctx.branch,
          do: FakeGitHub.change_pull(ctx.fake, n, head_sha: head)
    end

    run
  end

  defp rows(ctx),
    do: Repo.all(from(p in PullRequest, where: p.task_id == ^ctx.task.id, order_by: p.id))

  defp current(ctx), do: List.last(rows(ctx))

  defp status(ctx), do: Repo.get!(Task, ctx.task.id).status

  defp to(ctx, statuses, opts \\ %{}) do
    assert {:ok, _} = move(ctx.alice_scope, Repo.reload!(ctx.task), statuses, opts)
  end

  defp checks(ctx, sha, runs),
    do: FakeGitHub.update(ctx.fake, &%{&1 | checks: Map.put(&1.checks, sha, runs)})

  defp success(ctx, sha), do: checks(ctx, sha, [FakeGitHub.check_run("test", "success")])

  # Pull request #n of the task branch on GitHub (`attrs` of the fake)
  # and its row (`row`).
  defp open_pr(ctx, n, head, attrs \\ %{}, row \\ %{}) do
    FakeGitHub.put_pull(ctx.fake, n, Map.merge(%{head_ref: ctx.branch, head_sha: head}, attrs))
    pr_row(ctx, Map.merge(%{number: n, head_sha: head, state: :open}, row))
  end

  # A merged pull request #n at `head`, recorded as merged.
  defp merged_pr(ctx, n, head) do
    open_pr(ctx, n, head, %{merged: true, state: "closed"}, %{
      state: :merged,
      merged_at: DateTime.utc_now(),
      included_sha: head
    })
  end

  defp clear_jobs, do: Repo.delete_all(Oban.Job)

  # BOS verified by alice at `sha` with an open pull request #1 at it.
  defp verified_with_pr(ctx, sha \\ sha("c")) do
    push!(ctx, sha, sha("0"))
    to(ctx, [:in_progress, :done, :verified])
    open_pr(ctx, 1, sha)
  end

  describe "PR 的目标状态" do
    test "the first push opens a draft (首次推送)", ctx do
      push!(ctx, sha("c"), sha("0"))
      to(ctx, [:in_progress])
      clear_jobs()

      assert :ok = reconcile(ctx)

      assert [%{"title" => title, "head" => head, "base" => "main", "draft" => true} = body] =
               for(
                 %{method: "POST", path: "/repos/acme/app/pulls", body: b} <-
                   FakeGitHub.requests_with_bodies(ctx.fake),
                 do: b
               )

      assert title == "#{ctx.task.ident}: #{ctx.task.title}"
      assert head == ctx.branch
      assert body["body"] =~ "/w/#{ctx.workspace.slug}/t/#{ctx.task.ident}"

      assert %PullRequest{state: :draft, number: 1, head_sha: head_sha, branch: branch} =
               current(ctx)

      assert head_sha == sha("c") and branch == ctx.branch
      assert_enqueued(worker: ReconcilePR, args: %{task_id: ctx.task.id})
    end

    test "drafts not supported: a normal pull request, never converted", ctx do
      FakeGitHub.update(ctx.fake, &%{&1 | create_errors: ["draft"]})
      push!(ctx, sha("c"), sha("0"))
      to(ctx, [:in_progress])

      assert :ok = reconcile(ctx)
      assert %PullRequest{state: :open, draft_supported: false} = current(ctx)

      assert :ok = reconcile(ctx)
      refute FakeGitHub.requested?(ctx.fake, "POST", "/graphql")
    end

    test "done makes it ready for review (完成后可评审)", ctx do
      push!(ctx, sha("c"), sha("0"))
      to(ctx, [:in_progress, :done])
      open_pr(ctx, 1, sha("c"), %{draft: true}, %{state: :draft})

      assert :ok = reconcile(ctx)
      assert FakeGitHub.requested?(ctx.fake, "POST", "/graphql")
      refute FakeGitHub.pull(ctx.fake, 1).draft
      assert %PullRequest{state: :open} = current(ctx)
    end

    test "cancelled closes without deleting the branch, restored reopens as a draft (撤销与恢复)",
         ctx do
      push!(ctx, sha("c"), sha("0"))
      to(ctx, [:in_progress])
      open_pr(ctx, 1, sha("c"))
      to(ctx, [:cancelled])

      assert :ok = reconcile(ctx)
      assert %PullRequest{state: :closed, closed_by_helmsman: true} = current(ctx)
      assert FakeGitHub.pull(ctx.fake, 1).state == "closed"
      refute FakeGitHub.requested?(ctx.fake, "DELETE", ctx.branch)
      assert FakeGitHub.get(ctx.fake).refs[ctx.branch] == sha("c")

      to(ctx, [:new])
      assert :ok = reconcile(ctx)
      assert FakeGitHub.pull(ctx.fake, 1).state == "open"
      assert :ok = reconcile(ctx)
      assert FakeGitHub.pull(ctx.fake, 1).draft
      assert %PullRequest{state: :draft, closed_by_helmsman: false} = current(ctx)
    end

    test "closed on GitHub by someone else: recorded and blocked (被人在 GitHub 上关闭)", ctx do
      verified_with_pr(ctx)
      FakeGitHub.change_pull(ctx.fake, 1, state: "closed")

      assert :ok = reconcile(ctx)

      assert %PullRequest{state: :closed, merge_status: :blocked, merge_reason: :pr_closed} =
               current(ctx)

      assert status(ctx) == :verified
      refute FakeGitHub.requested?(ctx.fake, "PATCH", "/pulls/1")
    end

    test "merged on GitHub without a webhook: the sweep records it (PR 在 GitHub 上被外部合并)",
         ctx do
      push!(ctx, sha("c"), sha("0"))
      to(ctx, [:in_progress, :done])
      open_pr(ctx, 1, sha("c"), %{}, %{reconciled_at: DateTime.add(DateTime.utc_now(), -600)})

      FakeGitHub.change_pull(ctx.fake, 1,
        merged: true,
        state: "closed",
        merge_commit_sha: sha("e")
      )

      clear_jobs()

      assert ctx.task.id in ReconcileSweep.due()
      assert :ok = perform_job(ReconcileSweep, %{})
      assert [%Oban.Job{args: args}] = all_enqueued(worker: ReconcilePR)
      assert :ok = perform_job(ReconcilePR, args)

      assert %PullRequest{state: :merged, merged_at: %DateTime{}, included_sha: included} =
               current(ctx)

      assert included == sha("c")
      assert status(ctx) == :done
      refute FakeGitHub.requested?(ctx.fake, "PUT", "/pulls/1/merge")
    end

    test "merged, reopened and pushed again: a new current pull request (合并后重开再推送)", ctx do
      verified_with_pr(ctx)
      success(ctx, sha("c"))
      assert :ok = reconcile(ctx)
      assert :ok = reconcile(ctx)
      assert %PullRequest{state: :merged} = current(ctx)

      to(ctx, [:in_progress])
      push!(ctx, sha("d"), sha("c"))
      assert :ok = reconcile(ctx)

      assert [%{number: 1, state: :merged}, %{number: 2, state: :draft, head_sha: head}] =
               rows(ctx)

      assert head == sha("d")
    end

    test "after a merge the deleted branch is restored before a new pull request", ctx do
      push!(ctx, sha("c"), sha("0"))
      to(ctx, [:in_progress])
      merged_pr(ctx, 1, sha("c"))

      # The branch was deleted on GitHub, then a late push was recorded.
      pushed_run(ctx, sha("d"), sha("c"))
      FakeGitHub.update(ctx.fake, &%{&1 | refs: %{}})
      FakeGitHub.update(ctx.fake, &%{&1 | compare: %{{sha("d"), sha("c")} => "behind"}})

      assert :ok = reconcile(ctx)

      assert [%{method: "POST", path: "/repos/acme/app/pulls"} | _] =
               Enum.filter(
                 FakeGitHub.requests(ctx.fake),
                 &(&1.method == "POST" and &1.path =~ "pulls")
               )

      assert FakeGitHub.requested?(ctx.fake, "POST", "/git/refs")
      assert FakeGitHub.get(ctx.fake).refs[ctx.branch] == sha("d")
      assert %PullRequest{number: 2, head_sha: head} = current(ctx)
      assert head == sha("d")
    end

    test "a branch that cannot be restored: branch_missing", ctx do
      push!(ctx, sha("c"), sha("0"))
      to(ctx, [:in_progress])
      merged_pr(ctx, 1, sha("c"))

      pushed_run(ctx, sha("d"), sha("c"))

      FakeGitHub.update(
        ctx.fake,
        &%{&1 | refs: %{}, fail_create_ref: true, compare: %{{sha("d"), sha("c")} => "diverged"}}
      )

      assert :ok = reconcile(ctx)
      assert [%PullRequest{merge_status: :blocked, merge_reason: :branch_missing}] = rows(ctx)
    end
  end

  describe "finding unrecorded pull requests" do
    test "created but not recorded: found next time, not created again (第二个 PR 创建后未记录)",
         ctx do
      push!(ctx, sha("c"), sha("0"))
      to(ctx, [:in_progress])
      merged_pr(ctx, 12, sha("c"))

      push!(ctx, sha("d"), sha("c"))
      FakeGitHub.update(ctx.fake, &%{&1 | next_number: 15})

      Process.put(:helmsman_test_hook, fn
        :pull_request_created -> raise "crash before recording"
        _ -> :ok
      end)

      assert_raise RuntimeError, fn ->
        ReconcilePR.serially(ctx.task.id, fn -> Reconcile.run(ctx.task.id) end)
      end

      Process.delete(:helmsman_test_hook)
      assert [%{number: 12}] = rows(ctx)
      assert FakeGitHub.pull(ctx.fake, 15).state == "open"

      assert :ok = reconcile(ctx)
      assert [%{number: 12, state: :merged}, %{number: 15, state: :draft}] = rows(ctx)

      posts =
        Enum.count(
          FakeGitHub.requests(ctx.fake),
          &(&1 == %{method: "POST", path: "/repos/acme/app/pulls"})
        )

      assert posts == 1

      # Later reconciliations do not fail on "already exists" either.
      assert :ok = reconcile(ctx)
      assert length(rows(ctx)) == 2
    end

    test "422 already exists: found and recorded instead of created again", ctx do
      push!(ctx, sha("c"), sha("0"))
      to(ctx, [:in_progress])

      FakeGitHub.update(ctx.fake, fn s ->
        %{
          s
          | fail: fn
              "POST", "/repos/acme/app/pulls" ->
                FakeGitHub.put_pull(self_fake(), 7, %{head_ref: ctx.branch, head_sha: sha("c")})

                {422,
                 Jason.decode!(File.read!("test/support/fixtures/github/create_422_exists.json"))}

              _method, _path ->
                nil
            end
        }
      end)

      Process.put(:fake, ctx.fake)
      assert :ok = reconcile(ctx)
      assert [%PullRequest{number: 7}] = rows(ctx)
    end
  end

  defp self_fake, do: Process.get(:fake)

  describe "自动合并" do
    test "an independent person's verification merges at the verified commit (独立的人验收后合并)",
         ctx do
      verified_with_pr(ctx)
      success(ctx, sha("c"))

      assert :ok = reconcile(ctx)

      assert FakeGitHub.get(ctx.fake).last_merge == %{
               "sha" => sha("c"),
               "merge_method" => "squash"
             }

      assert %PullRequest{merge_status: :merged} = current(ctx)

      # The next reconciliation records the merge and cleans up.
      assert :ok = reconcile(ctx)

      assert %PullRequest{state: :merged, merged_at: %DateTime{}, branch_deleted_at: %DateTime{}} =
               current(ctx)

      refute Map.has_key?(FakeGitHub.get(ctx.fake).refs, ctx.branch)
      assert PullRequests.merged?(ctx.task.id)
    end

    test "merged branches and rescue branches (删除分支)", ctx do
      push!(ctx, sha("a"), sha("0"))
      pushed_run(ctx, sha("1"), sha("a"), rescue_branch: ctx.branch <> "-run-1")
      pushed_run(ctx, sha("2"), sha("a"), rescue_branch: ctx.branch <> "-run-2")
      push!(ctx, sha("c"), sha("a"))

      FakeGitHub.update(ctx.fake, fn s ->
        refs =
          Map.merge(s.refs, %{
            (ctx.branch <> "-run-1") => sha("1"),
            (ctx.branch <> "-run-2") => sha("2")
          })

        compare = %{{sha("1"), sha("c")} => "ahead", {sha("2"), sha("c")} => "diverged"}
        %{s | refs: refs, compare: compare}
      end)

      to(ctx, [:in_progress, :done, :verified])
      open_pr(ctx, 1, sha("c"))
      success(ctx, sha("c"))

      assert :ok = reconcile(ctx)
      assert :ok = reconcile(ctx)

      refs = FakeGitHub.get(ctx.fake).refs
      refute Map.has_key?(refs, ctx.branch)
      refute Map.has_key?(refs, ctx.branch <> "-run-1")
      assert refs[ctx.branch <> "-run-2"] == sha("2")
      assert %PullRequest{rescue_cleaned_at: %DateTime{}} = current(ctx)
    end

    test "the cleanup's check fails: nothing is deleted", ctx do
      verified_with_pr(ctx)
      success(ctx, sha("c"))
      assert :ok = reconcile(ctx)

      # A run starts while the merged pull request is read.
      FakeGitHub.update(ctx.fake, fn s ->
        %{
          s
          | fail: fn
              "GET", "/repos/acme/app/pulls/1" ->
                if Process.get(:started) != true do
                  Process.put(:started, true)
                  pushed_run(ctx, sha("c"), sha("0"), status: :running)
                end

                nil

              _m, _p ->
                nil
            end
        }
      end)

      assert :ok = reconcile(ctx)
      refute FakeGitHub.requested?(ctx.fake, "DELETE", ctx.branch)
      assert FakeGitHub.get(ctx.fake).refs[ctx.branch] == sha("c")
      assert %PullRequest{state: :merged, branch_deleted_at: nil} = current(ctx)
    end

    test "the branch moved after the merge: not deleted", ctx do
      verified_with_pr(ctx)
      success(ctx, sha("c"))
      assert :ok = reconcile(ctx)
      FakeGitHub.update(ctx.fake, &%{&1 | refs: Map.put(&1.refs, ctx.branch, sha("f"))})

      assert :ok = reconcile(ctx)
      refute FakeGitHub.requested?(ctx.fake, "DELETE", ctx.branch)
      assert %PullRequest{branch_deleted_at: nil} = current(ctx)
    end

    test "409: stale (验收后又有新推送)", ctx do
      verified_with_pr(ctx)
      success(ctx, sha("c"))
      FakeGitHub.update(ctx.fake, &%{&1 | merge_answers: [:head_changed]})

      assert :ok = reconcile(ctx)
      assert %PullRequest{merge_status: :stale, merge_reason: :head_changed} = current(ctx)
    end

    test "405 conflict: reopened for a fix", ctx do
      verified_with_pr(ctx)
      success(ctx, sha("c"))
      FakeGitHub.update(ctx.fake, &%{&1 | merge_answers: [:conflict]})

      assert :ok = reconcile(ctx)
      assert status(ctx) == :in_progress
      assert %PullRequest{auto_reopen_count: 1, merge_status: :none} = current(ctx)

      assert Repo.exists?(
               from(f in Entry,
                 where:
                   f.task_id == ^ctx.task.id and f.kind == :review and
                     like(f.content, "%merge conflicts%")
               )
             )
    end

    test "405 for required checks: waiting", ctx do
      verified_with_pr(ctx)
      success(ctx, sha("c"))
      FakeGitHub.update(ctx.fake, &%{&1 | merge_answers: [:checks]})

      assert :ok = reconcile(ctx)
      assert %PullRequest{merge_status: :waiting, merge_reason: :required_checks} = current(ctx)
    end

    test "405 otherwise: blocked with GitHub's message", ctx do
      verified_with_pr(ctx)
      success(ctx, sha("c"))

      FakeGitHub.update(
        ctx.fake,
        &%{&1 | merge_answers: [{:rejected, "At least 1 approving review is required."}]}
      )

      assert :ok = reconcile(ctx)

      assert %PullRequest{merge_status: :blocked, merge_reason: :merge_rejected, merge_note: note} =
               current(ctx)

      assert note == "At least 1 approving review is required. Resolve it on GitHub."
    end

    test "reopened before the merge: the merge is not called (合并前任务被重开)", ctx do
      verified_with_pr(ctx)
      success(ctx, sha("c"))

      FakeGitHub.update(ctx.fake, fn s ->
        %{
          s
          | fail: fn
              "GET", "/repos/acme/app/commits/" <> _ ->
                if Process.get(:reopened) != true do
                  Process.put(:reopened, true)
                  {:ok, _} = Tasks.transition(ctx.alice_scope, ctx.task.ident, :in_progress)
                  clear_jobs()
                end

                nil

              _m, _p ->
                nil
            end
        }
      end)

      assert :ok = reconcile(ctx)
      refute FakeGitHub.requested?(ctx.fake, "PUT", "/merge")
      assert_enqueued(worker: ReconcilePR, args: %{task_id: ctx.task.id})
    end

    test "pending CI: waiting, polled later", ctx do
      verified_with_pr(ctx)
      checks(ctx, sha("c"), [FakeGitHub.check_run("test", nil)])
      clear_jobs()

      assert :ok = reconcile(ctx)

      assert %PullRequest{
               merge_status: :waiting,
               merge_reason: :ci_pending,
               waiting_since: %DateTime{}
             } = current(ctx)

      assert_enqueued(
        worker: ReconcilePR,
        args: %{task_id: ctx.task.id},
        scheduled_at: {DateTime.add(DateTime.utc_now(), 60), delta: 10}
      )

      refute FakeGitHub.requested?(ctx.fake, "PUT", "/merge")
    end

    test "CI failed: reopened, then converted back to a draft", ctx do
      verified_with_pr(ctx)
      checks(ctx, sha("c"), [FakeGitHub.check_run("test (ubuntu)", "failure")])

      assert :ok = reconcile(ctx)
      assert status(ctx) == :in_progress
      assert :ok = reconcile(ctx)
      assert FakeGitHub.pull(ctx.fake, 1).draft
    end

    test "the repository is unavailable: blocked without calling GitHub", ctx do
      verified_with_pr(ctx)

      Repo.update_all(where(Helmsman.GitHub.Repository, id: ^ctx.repository.id),
        set: [archived: true]
      )

      assert :ok = reconcile(ctx)
      assert FakeGitHub.requests(ctx.fake) == []

      assert %PullRequest{merge_status: :blocked, merge_reason: :repository_unavailable} =
               current(ctx)
    end

    test "rate limited: snoozed", ctx do
      verified_with_pr(ctx)

      FakeGitHub.update(
        ctx.fake,
        &%{
          &1
          | fail: fn
              _m, "/repos/" <> _ -> {429, %{"message" => "slow down"}}
              _m, _p -> nil
            end
        }
      )

      assert {:snooze, seconds} = reconcile(ctx)
      assert seconds in 50..61
    end
  end

  describe "PR 对账: rebinding to another repository (改绑到另一个仓库)" do
    test "the old repository's pull request is left alone, the new one gets its own", ctx do
      # BOS has #12 in acme/app; the project moves to acme/other, which has
      # an unrelated #12.
      push!(ctx, sha("a"), sha("0"))
      to(ctx, [:in_progress])
      pr_row(ctx, %{number: 12, head_sha: sha("a")})

      other = repository_fixture(ctx.installation, %{owner: "acme", name: "other"})
      bind_repository(ctx.project, other)
      fake = FakeGitHub.start("acme", "other")
      FakeGitHub.put_pull(fake, 12, %{head_ref: "feature", head_sha: sha("9")})
      to(ctx, [:cancelled])

      assert :ok = reconcile(ctx)
      refute Enum.any?(FakeGitHub.requests(fake), &(&1.path =~ "/repos/acme/app"))
      refute FakeGitHub.requested?(fake, "GET", "/repos/acme/other/pulls/12")
      assert PullRequests.get(ctx.alice_scope, ctx.task.ident) == {:ok, nil}
      assert FakeGitHub.pull(fake, 12).state == "open"

      # A push in acme/other opens a pull request there.
      to(ctx, [:new, :in_progress])
      ctx = %{ctx | repository: other, fake: fake}
      push!(ctx, sha("b"), sha("0"))

      assert :ok = reconcile(ctx)
      refute Enum.any?(FakeGitHub.requests(fake), &(&1.path =~ "/repos/acme/app"))
      assert %PullRequest{repository_id: repository_id, number: 13} = current(ctx)
      assert repository_id == other.id

      to(ctx, [:done, :verified])
      assert latest_verification(ctx.task).verified_sha == sha("b")
    end
  end

  describe "the project changes while GitHub is read (code-review-2 P1)" do
    # `change` runs once, from inside the stub, when `path` is first read.
    defp during(ctx, method, path, change) do
      FakeGitHub.update(ctx.fake, fn s ->
        %{
          s
          | fail: fn
              ^method, ^path ->
                unless Process.get(:changed) do
                  Process.put(:changed, true)
                  change.()
                end

                nil

              _m, _p ->
                nil
            end
        }
      end)
    end

    # Every write to a repository (installation tokens aside).
    defp writes(fake) do
      Enum.filter(FakeGitHub.requests(fake), fn %{method: m, path: p} ->
        m != "GET" and not String.starts_with?(p, "/app/installations/")
      end)
    end

    test "unbound: no merge of the old repository's pull request", ctx do
      verified_with_pr(ctx)
      success(ctx, sha("c"))

      during(ctx, "GET", "/repos/acme/app/pulls/1", fn ->
        {:ok, _} =
          Helmsman.Projects.update_github_settings(ctx.alice_scope, ctx.project.key, %{
            repository_id: nil
          })
      end)

      assert :ok = reconcile(ctx)
      assert writes(ctx.fake) == []
      assert_enqueued(worker: ReconcilePR, args: %{task_id: ctx.task.id})

      # The next reconciliation does nothing: the pull request is no longer managed.
      assert :ok = reconcile(ctx)
      assert writes(ctx.fake) == []
    end

    test "rebound to a repository with the same number: neither is written", ctx do
      verified_with_pr(ctx)
      success(ctx, sha("c"))
      other = repository_fixture(ctx.installation, %{owner: "acme", name: "other"})

      during(ctx, "GET", "/repos/acme/app/pulls/1", fn ->
        bind_repository(ctx.project, other)
      end)

      assert :ok = reconcile(ctx)
      assert writes(ctx.fake) == []
      refute Enum.any?(FakeGitHub.requests(ctx.fake), &(&1.path =~ "/repos/acme/other"))
    end

    test "the policy becomes manual: no automatic merge", ctx do
      verified_with_pr(ctx)
      success(ctx, sha("c"))

      during(ctx, "GET", "/repos/acme/app/commits/#{sha("c")}/status", fn ->
        {:ok, _} =
          Helmsman.Projects.update_github_settings(ctx.alice_scope, ctx.project.key, %{
            merge_policy: "manual"
          })
      end)

      assert :ok = reconcile(ctx)
      refute FakeGitHub.requested?(ctx.fake, "PUT", "/merge")
      assert :ok = reconcile(ctx)
      refute FakeGitHub.requested?(ctx.fake, "PUT", "/merge")
      assert %PullRequest{merge_reason: :policy_manual} = current(ctx)
    end

    test "cancelled while the pull request is read: not closed in the old repository", ctx do
      push!(ctx, sha("c"), sha("0"))
      to(ctx, [:in_progress])
      open_pr(ctx, 1, sha("c"))
      to(ctx, [:cancelled])

      during(ctx, "GET", "/repos/acme/app/pulls/1", fn ->
        Repo.update_all(where(Helmsman.Projects.Project, id: ^ctx.project.id),
          set: [repository_id: nil]
        )
      end)

      assert :ok = reconcile(ctx)
      assert writes(ctx.fake) == []
      assert FakeGitHub.pull(ctx.fake, 1).state == "open"
    end

    test "unbound before the branch is deleted: no DELETE", ctx do
      verified_with_pr(ctx)
      success(ctx, sha("c"))
      assert :ok = reconcile(ctx)
      assert %PullRequest{merge_status: :merged} = current(ctx)

      during(ctx, "GET", "/repos/acme/app/git/ref/heads/#{ctx.branch}", fn ->
        Repo.update_all(where(Helmsman.Projects.Project, id: ^ctx.project.id),
          set: [repository_id: nil]
        )
      end)

      assert :ok = reconcile(ctx)
      refute FakeGitHub.requested?(ctx.fake, "DELETE", ctx.branch)
      assert FakeGitHub.get(ctx.fake).refs[ctx.branch] == sha("c")
    end
  end

  describe "the project changes while a pull request is created (code-review-4 P1)" do
    defp unbind(ctx) do
      {:ok, _} =
        Helmsman.Projects.update_github_settings(ctx.alice_scope, ctx.project.key, %{
          repository_id: nil
        })
    end

    defp posts(ctx, path),
      do: Enum.count(FakeGitHub.requests(ctx.fake), &(&1 == %{method: "POST", path: path}))

    setup ctx do
      to(ctx, [:in_progress])
      :ok
    end

    test "drafts not supported: the normal pull request is not created", ctx do
      push!(ctx, sha("c"), sha("0"))
      FakeGitHub.update(ctx.fake, &%{&1 | create_errors: ["draft"]})
      during(ctx, "POST", "/repos/acme/app/pulls", fn -> unbind(ctx) end)

      assert :ok = reconcile(ctx)
      assert posts(ctx, "/repos/acme/app/pulls") == 1
      assert FakeGitHub.get(ctx.fake).pulls == %{}
      assert rows(ctx) == []
      assert_enqueued(worker: ReconcilePR, args: %{task_id: ctx.task.id})
    end

    test "an invalid head: the branch is not restored", ctx do
      # A push record, but the branch is gone on GitHub.
      pushed_run(ctx, sha("c"), sha("0"))
      during(ctx, "POST", "/repos/acme/app/pulls", fn -> unbind(ctx) end)

      assert :ok = reconcile(ctx)
      assert posts(ctx, "/repos/acme/app/pulls") == 1
      assert posts(ctx, "/repos/acme/app/git/refs") == 0
    end

    test "the branch restored: no pull request after it", ctx do
      pushed_run(ctx, sha("c"), sha("0"))
      during(ctx, "POST", "/repos/acme/app/git/refs", fn -> unbind(ctx) end)

      assert :ok = reconcile(ctx)
      assert posts(ctx, "/repos/acme/app/git/refs") == 1
      assert posts(ctx, "/repos/acme/app/pulls") == 1
      assert FakeGitHub.get(ctx.fake).pulls == %{}

      # The next reconciliation does nothing: the project has no repository.
      assert :ok = reconcile(ctx)
      assert posts(ctx, "/repos/acme/app/pulls") == 1
    end
  end

  describe "the dependency hook (decision 21, code-review-2 P2)" do
    test "runs in the transaction that records the merge; a failure rolls it back", ctx do
      verified_with_pr(ctx)
      success(ctx, sha("c"))
      assert :ok = reconcile(ctx)
      test = self()
      task_id = ctx.task.id

      Process.put(:helmsman_test_hook, fn
        {:after_merge, ^task_id} ->
          send(
            test,
            {:hook, Repo.in_transaction?(), Repo.get!(PullRequest, current(ctx).id).merged_at}
          )

          raise "dependency hook failed"

        _ ->
          :ok
      end)

      assert_raise RuntimeError, fn -> reconcile(ctx) end
      assert_receive {:hook, true, %DateTime{}}
      assert %PullRequest{merged_at: nil} = current(ctx)

      Process.delete(:helmsman_test_hook)
      assert :ok = reconcile(ctx)
      assert %PullRequest{merged_at: %DateTime{}, included_sha: included} = current(ctx)
      assert included == sha("c")
    end
  end

  describe "serial runs" do
    test "a wake-up during a run queues the next one", ctx do
      {:ok, job} = Oban.insert(ReconcilePR.new(%{task_id: ctx.task.id}))
      Repo.update_all(where(Oban.Job, id: ^job.id), set: [state: "executing"])

      PullRequests.wake(ctx.task.id)
      assert length(all_enqueued(worker: ReconcilePR, args: %{task_id: ctx.task.id})) == 1
    end

    test "a wake-up brings a delayed poll forward; a poll keeps an earlier job", ctx do
      PullRequests.poll(ctx.task.id, 900)
      PullRequests.wake(ctx.task.id)

      assert [%{scheduled_at: at}] =
               all_enqueued(worker: ReconcilePR, args: %{task_id: ctx.task.id})

      assert DateTime.diff(at, DateTime.utc_now()) < 5

      PullRequests.poll(ctx.task.id, 600)

      assert [%{scheduled_at: at}] =
               all_enqueued(worker: ReconcilePR, args: %{task_id: ctx.task.id})

      assert DateTime.diff(at, DateTime.utc_now()) < 5
    end

    test "a poll brings a later poll forward", ctx do
      PullRequests.poll(ctx.task.id, 900)
      PullRequests.poll(ctx.task.id, 60)

      assert [%{scheduled_at: at}] =
               all_enqueued(worker: ReconcilePR, args: %{task_id: ctx.task.id})

      assert DateTime.diff(at, DateTime.utc_now()) in 50..61
    end
  end

  test "a project without a repository: nothing happens", ctx do
    Repo.update_all(where(Helmsman.Projects.Project, id: ^ctx.project.id),
      set: [repository_id: nil]
    )

    push!(ctx, sha("c"), sha("0"))
    to(ctx, [:in_progress, :done, :verified])

    assert :ok = reconcile(ctx)
    assert FakeGitHub.requests(ctx.fake) == []
    assert rows(ctx) == []
  end

  test "no GitHub call inside a transaction, reconciled_at written", ctx do
    verified_with_pr(ctx)
    success(ctx, sha("c"))
    assert :ok = reconcile(ctx)
    assert %PullRequest{reconciled_at: %DateTime{}} = current(ctx)
  end
end
