defmodule Helmsman.Tasks.VerifyLocalTest do
  # add-local-repositories 2.6: verifying a task of a local-mode project
  # records the latest delivered commit and nothing else (decision 10).
  use Helmsman.DataCase, async: true
  use Oban.Testing, repo: Helmsman.Repo

  import Helmsman.GitRunFixtures, only: [sha: 1]
  import Helmsman.LocalRepositoriesFixtures
  import Helmsman.RunsFixtures

  alias Helmsman.{Events, Tasks}
  alias Helmsman.LocalRepositories.TaskLocalBranch
  alias Helmsman.Tasks.{TaskEvent, VerifiedSha}

  setup do
    ctx = local_run_fixture()
    {_bob, reviewer} = member_scope_fixture(ctx.workspace, :member)
    Map.put(ctx, :reviewer, reviewer)
  end

  defp branch!(ctx, head, repo \\ nil) do
    Repo.insert!(%TaskLocalBranch{
      workspace_id: ctx.workspace.id,
      task_id: ctx.task.id,
      local_repository_id: (repo || ctx.local_repo).id,
      branch: ctx.branch,
      head_sha: head
    })
  end

  defp verify(ctx) do
    {:ok, _} = Tasks.transition(ctx.alice_scope, ctx.task.ident, :in_progress)
    {:ok, _} = Tasks.transition(ctx.alice_scope, ctx.task.ident, :done)
    {:ok, _} = Tasks.transition(ctx.reviewer, ctx.task.ident, :verified)

    Repo.all(
      from(e in TaskEvent,
        where: e.task_id == ^ctx.task.id,
        order_by: e.id,
        select: {e.to_status, e.verified_sha}
      )
    )
  end

  test "verifying merges nothing and records the latest delivery (scenario)", ctx do
    branch!(ctx, sha("c"))
    :ok = Events.subscribe(Events.topic(:daemon, ctx.daemon.id))

    assert [{:new, nil}, {:in_progress, nil}, {:done, nil}, {:verified, head}] = verify(ctx)
    assert head == sha("c")

    assert %TaskLocalBranch{state: "open", merged_at: nil} =
             Repo.get_by!(TaskLocalBranch, task_id: ctx.task.id)

    refute_receive {:daemon_config_changed}, 50
    refute_enqueued(queue: :github)
    refute_enqueued(queue: :github_pr)
  end

  test "no delivery, or a branch on a repository the project no longer uses: nothing", ctx do
    assert VerifiedSha.compute(ctx.task) == nil

    other = local_repository_fixture(ctx.workspace, ctx.daemon, %{name: "other"})
    branch!(ctx, sha("c"), other)
    assert VerifiedSha.compute(ctx.task) == nil
    assert [_, _, _, {:verified, nil}] = verify(ctx)
  end
end
