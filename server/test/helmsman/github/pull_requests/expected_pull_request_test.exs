defmodule Helmsman.GitHub.PullRequests.ExpectedPullRequestTest do
  # add-github-ui code review 3 P1 / domain request 1 R7: merge_now/3 and
  # reverify/3 act only on the pull request the person confirmed
  # (`expected_pull_request`), compared under the row lock.
  use Helmsman.DataCase, async: true
  use Oban.Testing, repo: Helmsman.Repo

  import Helmsman.GitHubFixtures
  import Helmsman.PullRequestFixtures

  alias Helmsman.FakeGitHub
  alias Helmsman.Feedback.Entry
  alias Helmsman.GitHub.{PullRequest, PullRequests}
  alias Helmsman.GitHub.Workers.ReconcilePR
  alias Helmsman.Projects.Project
  alias Helmsman.Tasks.TaskEvent

  @old %{repository: "acme/app", number: 1}
  @new %{repository: "acme/api", number: 7}

  setup do
    ctx = pr_fixture()
    fake = FakeGitHub.start()
    pushed_run(ctx, sha("c"), sha("0"))
    {:ok, _} = move(ctx.alice_scope, ctx.task, [:in_progress, :done, :verified])
    cancel_pending(ctx.task)
    FakeGitHub.put_pull(fake, 1, %{head_ref: ctx.branch, head_sha: sha("c")})

    old = pr_row(ctx, %{number: 1, head_sha: sha("c"), merge_reason: :policy_manual})
    other_repo = repository_fixture(ctx.installation, %{owner: "acme", name: "api"})

    other =
      pr_row(ctx, %{
        repository: other_repo,
        number: 7,
        head_sha: sha("c"),
        merge_reason: :policy_manual
      })

    Repo.delete_all(Oban.Job)
    Map.merge(ctx, %{fake: fake, old: old, other: other, other_repo: other_repo})
  end

  defp rebind(ctx, repository_id),
    do: Repo.update_all(where(Project, id: ^ctx.project.id), set: [repository_id: repository_id])

  defp writes(ctx) do
    {Repo.aggregate(from(f in Entry, where: f.task_id == ^ctx.task.id), :count),
     Repo.aggregate(from(e in TaskEvent, where: e.task_id == ^ctx.task.id), :count),
     Repo.reload!(ctx.old).merge_request, Repo.reload!(ctx.other).merge_request}
  end

  defp stale(ctx, pr, sha) do
    pushed_run(ctx, sha, sha("c"))
    FakeGitHub.change_pull(ctx.fake, 1, head_sha: sha)

    Repo.update_all(where(PullRequest, id: ^pr.id),
      set: [head_sha: sha, merge_status: :stale, merge_reason: :head_changed]
    )
  end

  describe "merge_now/3" do
    test "the confirmed pull request is still the current one", ctx do
      assert {:ok, view} =
               PullRequests.merge_now(ctx.alice_scope, ctx.task.ident,
                 expected_pull_request: @old
               )

      assert %{repository: %{full_name: "acme/app"}, number: 1, merge_request: %{}} = view
      assert Repo.reload!(ctx.old).merge_request
      assert Repo.reload!(ctx.other).merge_request == nil
      assert_enqueued(worker: ReconcilePR, args: %{task_id: ctx.task.id})
    end

    test "rebound after the confirmation: nothing is registered on either", ctx do
      rebind(ctx, ctx.other_repo.id)
      before = writes(ctx)

      for opts <- [[], [skip_independence: "hotfix"]] do
        assert PullRequests.merge_now(
                 ctx.alice_scope,
                 ctx.task.ident,
                 [expected_pull_request: @old] ++ opts
               ) == {:error, {:pull_request_changed, @new}}
      end

      assert writes(ctx) == before
      assert {_, _, nil, nil} = before
      refute_enqueued(worker: ReconcilePR)
    end

    test "rebound to a repository without a pull request, or unbound", ctx do
      bare = repository_fixture(ctx.installation, %{owner: "acme", name: "bare"})

      for repository_id <- [bare.id, nil] do
        rebind(ctx, repository_id)

        assert PullRequests.merge_now(ctx.alice_scope, ctx.task.ident,
                 expected_pull_request: @old
               ) == {:error, {:pull_request_changed, nil}}
      end

      assert Repo.reload!(ctx.old).merge_request == nil
    end

    test "a newer pull request in the same repository", ctx do
      newer = pr_row(ctx, %{number: 2, head_sha: sha("c")})

      assert PullRequests.merge_now(ctx.alice_scope, ctx.task.ident, expected_pull_request: @old) ==
               {:error, {:pull_request_changed, %{repository: "acme/app", number: 2}}}

      assert Repo.reload!(newer).merge_request == nil
    end

    test "without the option the current pull request is used (unchanged)", ctx do
      rebind(ctx, ctx.other_repo.id)
      assert {:ok, %{number: 7}} = PullRequests.merge_now(ctx.alice_scope, ctx.task.ident)
      assert Repo.reload!(ctx.other).merge_request
    end

    test "a malformed expectation is refused before anything", ctx do
      for bad <- [{"acme/app", 1}, %{repository: "acme/app"}, %{repository: nil, number: 1}] do
        assert PullRequests.merge_now(ctx.alice_scope, ctx.task.ident, expected_pull_request: bad) ==
                 {:error, :invalid_expected_pull_request}
      end

      assert Repo.reload!(ctx.old).merge_request == nil
    end
  end

  describe "reverify/3" do
    test "the confirmed pull request is still the current one", ctx do
      stale(ctx, ctx.old, sha("d"))

      assert {:ok, %{verified_sha: verified}} =
               PullRequests.reverify(ctx.alice_scope, ctx.task.ident,
                 expected_pull_request: @old,
                 expected_head_sha: sha("d")
               )

      assert verified == sha("d")
    end

    test "rebound before the call: refused without calling GitHub", ctx do
      stale(ctx, ctx.old, sha("d"))
      rebind(ctx, ctx.other_repo.id)
      before = writes(ctx)
      requests = FakeGitHub.requests(ctx.fake)

      # Both pull requests have the same head: the SHA alone would pass.
      assert PullRequests.reverify(ctx.alice_scope, ctx.task.ident,
               expected_pull_request: @old,
               expected_head_sha: sha("d")
             ) == {:error, {:pull_request_changed, @new}}

      assert writes(ctx) == before
      assert FakeGitHub.requests(ctx.fake) == requests
    end

    test "rebound after GitHub was read, before the row lock", ctx do
      stale(ctx, ctx.old, sha("d"))
      stale(ctx, ctx.other, sha("d"))
      before = writes(ctx)

      Process.put(:helmsman_test_hook, fn
        :reverify_locking -> rebind(ctx, ctx.other_repo.id)
        _other -> :ok
      end)

      assert PullRequests.reverify(ctx.alice_scope, ctx.task.ident, expected_pull_request: @old) ==
               {:error, {:pull_request_changed, @new}}

      Process.delete(:helmsman_test_hook)
      assert writes(ctx) == before
    end
  end
end
