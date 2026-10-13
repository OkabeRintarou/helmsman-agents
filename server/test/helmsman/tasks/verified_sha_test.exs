defmodule Helmsman.Tasks.VerifiedShaTest do
  # add-pr-reconcile-merge 1.2: the commit a move to `verified` records
  # (decision 15; pull-requests "验收时记下的提交").
  use Helmsman.DataCase, async: true

  import Helmsman.GitHubFixtures
  import Helmsman.PullRequestFixtures

  alias Helmsman.Tasks.VerifiedSha

  setup do
    # Any HTTP call fails the test: the transition must not call GitHub.
    stub_github(fn _conn -> raise "GitHub must not be called while verifying" end)
    pr_fixture()
  end

  defp verify(ctx) do
    assert {:ok, detail} = move(ctx.alice_scope, ctx.task, [:in_progress, :done, :verified])
    assert List.last(detail.history).verified_sha == latest_verification(ctx.task).verified_sha
    latest_verification(ctx.task).verified_sha
  end

  test "the head of the latest push to the task branch (scenario)", ctx do
    earlier = DateTime.add(DateTime.utc_now(), -60)
    pushed_run(ctx, sha("b"), sha("a"), claimed_at: earlier)
    pushed_run(ctx, sha("c"), sha("b"))

    assert verify(ctx) == sha("c")
  end

  test "by claim time, not by insertion order", ctx do
    pushed_run(ctx, sha("c"), sha("b"))
    pushed_run(ctx, sha("b"), sha("a"), claimed_at: DateTime.add(DateTime.utc_now(), -60))

    assert verify(ctx) == sha("c")
  end

  test "no push: nil", ctx do
    assert verify(ctx) == nil
  end

  test "a push to a rescue branch does not count", ctx do
    pushed_run(ctx, sha("d"), sha("a"), rescue_branch: ctx.branch <> "-run-1")
    assert verify(ctx) == nil
  end

  test "pushes to the repository the project was bound to before do not count", ctx do
    pushed_run(ctx, sha("e"), sha("a"))
    other = repository_fixture(ctx.installation, %{owner: "acme", name: "other"})
    bind_repository(ctx.project, other)

    assert verify(ctx) == nil
  end

  test "a project without a repository: nil", ctx do
    pushed_run(ctx, sha("e"), sha("a"))

    Repo.update_all(where(Helmsman.Projects.Project, id: ^ctx.project.id),
      set: [repository_id: nil]
    )

    assert VerifiedSha.compute(Repo.reload!(ctx.task)) == nil
    assert verify(ctx) == nil
  end

  test "other moves record nothing", ctx do
    pushed_run(ctx, sha("c"), sha("b"))
    verify(ctx)

    assert {:ok, detail} = move(ctx.alice_scope, ctx.task, [:in_progress])
    assert List.last(detail.history).verified_sha == nil
  end
end
