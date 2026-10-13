defmodule Helmsman.GitHub.AutoReopenTest do
  # add-pr-reconcile-merge 1.6: automatic reopens and the question once
  # they are used up (decisions 8, 9; pull-requests "自动重开").
  use Helmsman.DataCase, async: true
  use Oban.Testing, repo: Helmsman.Repo

  import Helmsman.PullRequestFixtures

  alias Helmsman.FakeGitHub
  alias Helmsman.Feedback.Entry
  alias Helmsman.GitHub.PullRequest
  alias Helmsman.GitHub.Workers.ReconcilePR
  alias Helmsman.Runs.Run
  alias Helmsman.Tasks.{Task, TaskEvent}

  setup do
    ctx = pr_fixture()
    fake = FakeGitHub.start()
    pushed_run(ctx, sha("c"), sha("0"))
    FakeGitHub.update(fake, &%{&1 | refs: %{ctx.branch => sha("c")}})
    {:ok, _} = move(ctx.alice_scope, ctx.task, [:in_progress, :done, :verified])
    FakeGitHub.put_pull(fake, 1, %{head_ref: ctx.branch, head_sha: sha("c")})
    pr = pr_row(ctx, %{number: 1, head_sha: sha("c")})
    Map.merge(ctx, %{fake: fake, pr: pr})
  end

  defp reconcile(ctx), do: perform_job(ReconcilePR, %{task_id: ctx.task.id})

  defp fail_ci(ctx) do
    run =
      FakeGitHub.check_run("test (ubuntu)", "failure", %{
        "details_url" => "https://github.com/acme/app/actions/runs/7",
        "output" => %{"title" => "1 test failed", "summary" => "LoginTest: expected 200"}
      })

    FakeGitHub.update(ctx.fake, &%{&1 | checks: %{sha("c") => [run]}})
  end

  defp reviews(ctx, kind),
    do:
      Repo.all(
        from(f in Entry, where: f.task_id == ^ctx.task.id and f.kind == ^kind, order_by: f.id)
      )

  test "CI failed: a system review, back in progress, a fix run, then a draft (CI 失败)", ctx do
    fail_ci(ctx)
    assert :ok = reconcile(ctx)

    assert Repo.get!(Task, ctx.task.id).status == :in_progress
    [review] = reviews(ctx, :review)
    assert review.author_id == ctx.system.id

    assert review.content ==
             "CI failed on ccccccc (pull request #1):\n" <>
               "- test (ubuntu): failure https://github.com/acme/app/actions/runs/7\n\n" <>
               "1 test failed\n\nLoginTest: expected 200"

    assert [%Run{status: :queued, agent_id: agent_id, triggers: [trigger]}] =
             Repo.all(from(r in Run, where: r.task_id == ^ctx.task.id and r.status == :queued))

    assert agent_id == ctx.agent.id
    assert trigger["kind"] == "reopen" and trigger["reason"] == "ci_failed"

    assert %PullRequest{auto_reopen_count: 1, merge_status: :none, merge_reason: nil} =
             Repo.get!(PullRequest, ctx.pr.id)

    assert :ok = reconcile(ctx)
    assert FakeGitHub.pull(ctx.fake, 1).draft
  end

  test "merge conflict: the conflict review", ctx do
    FakeGitHub.update(ctx.fake, fn s ->
      %{
        s
        | checks: %{sha("c") => [FakeGitHub.check_run("test", "success")]},
          merge_answers: [:conflict]
      }
    end)

    assert :ok = reconcile(ctx)
    [review] = reviews(ctx, :review)

    assert review.content ==
             "Pull request #1 has merge conflicts with main. The next run merges main into " <>
               "#{ctx.branch}; resolve the conflicts there."

    last =
      Repo.one!(
        from(e in TaskEvent, where: e.task_id == ^ctx.task.id, order_by: [desc: e.id], limit: 1)
      )

    assert last.auto_reason == :merge_conflict
  end

  test "used up: failed, one question to the creator per verification (次数用尽)", ctx do
    Repo.update_all(where(PullRequest, id: ^ctx.pr.id), set: [auto_reopen_count: 3])
    fail_ci(ctx)

    assert :ok = reconcile(ctx)
    assert Repo.get!(Task, ctx.task.id).status == :verified

    assert %PullRequest{
             merge_status: :failed,
             merge_reason: :ci_failed_limit,
             escalated_event_id: v_id
           } =
             Repo.get!(PullRequest, ctx.pr.id)

    assert v_id == latest_verification(ctx.task).id
    assert [question] = reviews(ctx, :question)
    assert question.author_id == ctx.system.id

    assert question.content =~
             "@#{ctx.alice_scope.actor.name} #{ctx.task.ident} still fails (CI failed) after 3"

    assert question.content =~ "https://github.com/acme/app/pull/1"
    assert Repo.get!(Task, ctx.task.id).open_question

    # No run for the system's question; asking again does nothing.
    refute Repo.exists?(from(r in Run, where: r.task_id == ^ctx.task.id and r.status == :queued))
    assert :ok = reconcile(ctx)
    assert length(reviews(ctx, :question)) == 1
  end

  test "auto_reopen/2 :stale (a new verification meanwhile): the row is not changed", ctx do
    fail_ci(ctx)

    Process.put(:helmsman_test_hook, fn
      :before_auto_reopen ->
        v = latest_verification(ctx.task)
        Repo.insert!(%{v | id: nil, from_status: :verified, inserted_at: nil})

      _ ->
        :ok
    end)

    Repo.delete_all(Oban.Job)
    assert :ok = reconcile(ctx)
    Process.delete(:helmsman_test_hook)

    assert Repo.get!(Task, ctx.task.id).status == :verified
    assert %PullRequest{auto_reopen_count: 0} = Repo.get!(PullRequest, ctx.pr.id)
    assert reviews(ctx, :review) == []
    assert_enqueued(worker: ReconcilePR, args: %{task_id: ctx.task.id})
  end
end
