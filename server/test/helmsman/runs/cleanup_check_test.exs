defmodule Helmsman.Runs.CleanupCheckTest do
  # add-pr-reconcile-merge 1.10: the server's cleanup judgement (decision
  # 16; worktree-cleanup "服务端的清理判定").
  use Helmsman.DataCase, async: true

  import Helmsman.GitHubFixtures
  import Helmsman.LocalRepositoriesFixtures
  import Helmsman.PullRequestFixtures
  import Helmsman.RunsFixtures

  alias Helmsman.Daemons.DaemonWorkspace
  alias Helmsman.Runs
  alias Helmsman.Runs.Run
  alias Helmsman.Tasks.Task

  setup do
    ctx = pr_fixture()
    Map.put(ctx, :dctx, daemon_ctx(ctx.daemon))
  end

  defp check(ctx, idents) do
    items =
      for ident <- idents, do: %{workspace_id: ctx.workspace.id, ident: ident}

    assert {:ok, results} = Runs.cleanup_check(ctx.dctx, items)
    results
  end

  defp one(ctx, ident \\ nil), do: hd(check(ctx, [ident || ctx.task.ident]))

  defp status(ctx, status),
    do: Repo.update_all(where(Task, id: ^ctx.task.id), set: [status: status])

  test "verified, merged, nothing pending: deletable with the pushed heads (PR 已合并)", ctx do
    pushed_run(ctx, sha("a"), sha("0"))
    pushed_run(ctx, sha("b"), sha("a"), rescue_branch: ctx.branch <> "-run-9")
    status(ctx, :verified)
    pr_row(ctx, %{state: :merged})

    assert %{deletable: true, base_branch: "main", pushed_heads: heads, ident: ident} = one(ctx)
    assert Enum.sort(heads) == [sha("a"), sha("b")]
    assert ident == ctx.task.ident
  end

  test "the pull request is still open (PR 还开着)", ctx do
    pushed_run(ctx, sha("a"), sha("0"))
    status(ctx, :verified)
    pr_row(ctx, %{state: :open})
    assert %{deletable: false} = one(ctx)

    Repo.update_all(Helmsman.GitHub.PullRequest, set: [state: :closed])
    assert %{deletable: true} = one(ctx)
  end

  test "pushed without a pull request row: not yet", ctx do
    pushed_run(ctx, sha("a"), sha("0"))
    status(ctx, :cancelled)
    assert %{deletable: false, pushed_heads: [_]} = one(ctx)
  end

  test "a queued reply run (还有排队的运行); active runs; open statuses", ctx do
    status(ctx, :cancelled)
    assert %{deletable: true} = one(ctx)

    run = run_fixture(ctx.agent, %{task_id: ctx.task.id, lane: :reply, status: :queued})
    assert %{deletable: false} = one(ctx)

    for s <- [:deferred, :claimed, :running, :cancelling] do
      Repo.update_all(where(Run, id: ^run.id), set: [status: s])
      assert %{deletable: false} = one(ctx), "#{s}"
    end

    Repo.update_all(where(Run, id: ^run.id), set: [status: :failed])

    for {s, expected} <- [
          new: false,
          in_progress: false,
          done: false,
          rejected: true,
          verified: true
        ] do
      status(ctx, s)
      assert %{deletable: ^expected} = one(ctx)
    end
  end

  test "a workspace the daemon no longer serves (不再服务的工作区)", ctx do
    status(ctx, :cancelled)

    Repo.delete_all(
      where(DaemonWorkspace, daemon_id: ^ctx.daemon.id, workspace_id: ^ctx.workspace.id)
    )

    assert %{deletable: false, base_branch: nil, pushed_heads: []} = one(ctx)
  end

  test "a project without a repository: only the status and the runs", ctx do
    Repo.update_all(where(Helmsman.Projects.Project, id: ^ctx.project.id),
      set: [repository_id: nil]
    )

    status(ctx, :verified)
    assert %{deletable: true, base_branch: nil} = one(ctx)
  end

  test "a pull request still open in the repository the project left, no push in the new one",
       ctx do
    pushed_run(ctx, sha("a"), sha("0"))
    pr_row(ctx, %{state: :open})

    other =
      repository_fixture(ctx.installation, %{
        owner: "acme",
        name: "other",
        default_branch: "trunk"
      })

    bind_repository(ctx.project, other)
    status(ctx, :verified)

    assert %{deletable: true, base_branch: "trunk", pushed_heads: [head]} = one(ctx)
    assert head == sha("a")
  end

  test "at most 200 heads, newest first; any case; unknown tasks", ctx do
    now = DateTime.utc_now()

    for i <- 1..201 do
      pushed_run(ctx, String.pad_leading(Integer.to_string(i, 16), 40, "0"), sha("0"),
        claimed_at: DateTime.add(now, i)
      )
    end

    status(ctx, :verified)
    pr_row(ctx, %{state: :merged})

    [lower, unknown] = check(ctx, [String.downcase(ctx.task.ident), "NOPE-9"])
    assert %{deletable: true, pushed_heads: heads} = lower
    assert length(heads) == 200
    assert hd(heads) == String.pad_leading(Integer.to_string(201, 16), 40, "0")
    assert lower.ident == String.downcase(ctx.task.ident)
    assert %{deletable: false, pushed_heads: [], base_branch: nil} = unknown
  end

  describe "a project bound to a local repository (add-local-repositories)" do
    setup do
      ctx = local_run_fixture()
      repo = Repo.update!(Ecto.Changeset.change(ctx.local_repo, default_branch: "trunk"))
      Map.put(ctx, :local_repo, repo)
    end

    test "only the task status and its runs count; heads include local pushes", ctx do
      head = sha("c")

      local_run(ctx, %{
        status: :succeeded,
        finished_at: DateTime.utc_now(),
        push_status: :pushed,
        base_sha: sha("0"),
        head_sha: head,
        push_commits: [],
        pushed_at: DateTime.utc_now()
      })

      status(ctx, :in_progress)
      assert %{deletable: false} = one(ctx)

      status(ctx, :verified)
      assert %{deletable: true, base_branch: "trunk", pushed_heads: [^head]} = one(ctx)

      run = local_run(ctx, %{status: :queued, claimed_at: nil, started_at: nil})
      assert %{deletable: false} = one(ctx)

      set_local_run(run, status: :cancelled, finished_at: DateTime.utc_now())

      Repo.update_all(where(Helmsman.Projects.Project, id: ^ctx.project.id),
        set: [base_branch: "dev"]
      )

      assert %{deletable: true, base_branch: "dev"} = one(ctx)
    end
  end

  test "a reauthorized daemon is refused", ctx do
    assert Runs.cleanup_check(%{ctx.dctx | auth_epoch: ctx.dctx.auth_epoch + 1}, [
             %{workspace_id: ctx.workspace.id, ident: ctx.task.ident}
           ]) == {:error, :reauthorized}
  end
end
