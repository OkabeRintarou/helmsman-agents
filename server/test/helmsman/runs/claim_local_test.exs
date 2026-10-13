defmodule Helmsman.Runs.ClaimLocalTest do
  # add-local-repositories 2.4: claiming a run of a project bound to a local
  # repository (decisions 6, 7) and the git messages of such a run.
  use Helmsman.DataCase, async: true
  use Oban.Testing, repo: Helmsman.Repo

  @moduletag :capture_log

  import Helmsman.AgentsFixtures
  import Helmsman.GitHubFixtures
  import Helmsman.GitRunFixtures, only: [sha: 1]
  import Helmsman.LocalRepositoriesFixtures
  import Helmsman.ProjectsFixtures
  import Helmsman.RunsFixtures

  alias Helmsman.LocalRepositories.Workers.RecordBranch
  alias Helmsman.Runs
  alias Helmsman.Runs.Run
  alias HelmsmanProtocol.{Report, RunSpec}

  @base_url "http://localhost:4000"

  setup do
    ctx = dispatch_fixture()
    daemon = daemon_of(ctx.agent)

    Repo.update_all(from(d in Helmsman.Daemons.Daemon, where: d.id == ^daemon.id),
      set: [name: "alice-mbp"]
    )

    daemon = Repo.reload!(daemon)
    Map.merge(ctx, %{daemon: daemon, dctx: daemon_ctx(daemon)})
  end

  defp claim(ctx, protocol \\ HelmsmanProtocol.version()) do
    dctx = Map.put(ctx.dctx, :protocol, protocol)
    Runs.claim(dctx, @base_url, Runs.prefetch_push_tokens(dctx))
  end

  defp queued(ctx, project) do
    task = task_fixture(ctx.alice_scope, project.key)
    {task, run_fixture(ctx.agent, %{task_id: task.id})}
  end

  defp bound(ctx, attrs \\ %{}) do
    repo = local_repository_fixture(ctx.workspace, ctx.daemon, attrs)
    {repo, bind_local(ctx.project, repo)}
  end

  test "a normal claim (scenario): local repository, name and task branch, no path or token",
       ctx do
    counter = stub_push_tokens()
    {repo, project} = bound(ctx)
    {task, run} = queued(ctx, project)

    assert {:ok, [%RunSpec{repo: spec_repo, prompt: prompt}]} = claim(ctx)
    branch = "hm/#{ctx.workspace.id}/#{String.downcase(task.ident)}"

    assert %RunSpec.Repo{
             kind: :local,
             name: "app",
             base_branch: "main",
             branch: ^branch,
             rescue_branches: [],
             clone_url: nil,
             git_token: nil,
             git_token_expires_at: nil,
             github_repository_id: nil
           } = spec_repo

    assert %Run{status: :claimed, branch: ^branch, repository_id: nil} =
             claimed = Repo.reload!(run)

    assert claimed.local_repository_id == repo.id

    assert prompt =~
             "a git worktree of the local repository app on alice-mbp, on branch #{branch} " <>
               "(based on main)"

    assert prompt =~ "Helmsman delivers the branch to the repository for local review."
    refute prompt =~ "/home/alice"
    refute inspect(spec_repo) =~ "/home/alice"

    # No push token is fetched for a local repository.
    assert :counters.get(counter, 1) == 0
    refute_received {:push_token_request, _, _}
  end

  test "the runtime on another machine (scenario): failed, workspace_prepare", ctx do
    {other_daemon, _} =
      daemon_fixture(ctx.alice, %{workspace_ids: [ctx.workspace.id], name: "bob-pc"})

    repo = local_repository_fixture(ctx.workspace, other_daemon)
    project = bind_local(ctx.project, repo)
    {_task, run} = queued(ctx, project)

    assert {:ok, []} = claim(ctx)

    assert %Run{status: :failed, failure_reason: :workspace_prepare, error: error} =
             Repo.reload!(run)

    assert error =~ "This project's repository app is on bob-pc"
    assert error =~ "the agent's runtime is on another machine"
    refute_enqueued(worker: Helmsman.Runs.Workers.Retry)
  end

  test "an old daemon (scenario): failed, needs an upgrade", ctx do
    {_repo, project} = bound(ctx)
    {_task, run} = queued(ctx, project)

    assert {:ok, []} = claim(ctx, 1)

    assert %Run{status: :failed, failure_reason: :workspace_prepare, error: error} =
             Repo.reload!(run)

    assert error =~ "upgrade the daemon on alice-mbp"
  end

  test "unavailable or removed: failed, workspace_prepare", ctx do
    {repo, project} =
      bound(ctx, %{status: "unavailable", unavailable_reason: "not configured on the machine"})

    {_task, run} = queued(ctx, project)
    assert {:ok, []} = claim(ctx)

    assert %Run{status: :failed, failure_reason: :workspace_prepare, error: error} =
             Repo.reload!(run)

    assert error =~ "app on alice-mbp is not available: not configured on the machine"

    Repo.update_all(
      from(l in Helmsman.LocalRepositories.LocalRepository, where: l.id == ^repo.id),
      set: [status: "offline", unavailable_reason: nil, removed_at: DateTime.utc_now(:second)]
    )

    {_task, run} = queued(ctx, project)
    assert {:ok, []} = claim(ctx)
    assert %Run{failure_reason: :workspace_prepare, error: error} = Repo.reload!(run)
    assert error =~ "was removed"

    # Offline is not a reason to fail: the daemon claiming is the owner.
    Repo.update_all(
      from(l in Helmsman.LocalRepositories.LocalRepository, where: l.id == ^repo.id),
      set: [removed_at: nil]
    )

    {_task, run} = queued(ctx, project)
    assert {:ok, [%RunSpec{}]} = claim(ctx)
    assert Repo.reload!(run).status == :claimed
  end

  test "rescue branches come from the task's runs on this local repository, once each", ctx do
    {repo, project} = bound(ctx)
    other_repo = local_repository_fixture(ctx.workspace, ctx.daemon, %{name: "other"})
    github = repository_fixture(installation_fixture(ctx.workspace))
    {task, run} = queued(ctx, project)
    branch = "hm/#{ctx.workspace.id}/#{String.downcase(task.ident)}"

    conflict = fn rescue_branch, attrs ->
      run_fixture(
        ctx.agent,
        Map.merge(
          %{
            task_id: task.id,
            status: :failed,
            failure_reason: :push_conflict,
            finished_at: DateTime.utc_now(),
            daemon_id: ctx.daemon.id,
            branch: branch,
            push_status: :conflict,
            rescue_branch: rescue_branch,
            base_sha: sha("a"),
            head_sha: sha("b"),
            pushed_at: DateTime.utc_now()
          },
          attrs
        )
      )
    end

    conflict.("#{branch}-run-2", %{local_repository_id: repo.id})
    conflict.("#{branch}-run-1", %{local_repository_id: repo.id})
    conflict.("#{branch}-run-1", %{local_repository_id: repo.id})
    conflict.("#{branch}-run-9", %{local_repository_id: other_repo.id})
    conflict.("#{branch}-run-8", %{repository_id: github.id})

    assert {:ok, [%RunSpec{repo: %{rescue_branches: rescues}, prompt: prompt}]} = claim(ctx)
    assert rescues == ["#{branch}-run-2", "#{branch}-run-1"]

    assert prompt =~
             "Before this run Helmsman merged #{branch}-run-2, #{branch}-run-1 into #{branch}."

    assert Repo.reload!(run).status == :claimed
  end

  test "git_token: not_found for a local run; pushed: recorded as usual", ctx do
    {repo, project} = bound(ctx)
    task = task_fixture(ctx.alice_scope, project.key)
    branch = "hm/#{ctx.workspace.id}/#{String.downcase(task.ident)}"

    run =
      run_fixture(ctx.agent, %{
        task_id: task.id,
        status: :running,
        daemon_id: ctx.daemon.id,
        claimed_at: DateTime.utc_now(),
        local_repository_id: repo.id,
        branch: branch
      })

    assert {:error, :not_found} = Runs.git_token(ctx.dctx, run.id)

    report = %Report.Pushed{
      run_id: run.id,
      branch: branch,
      base_sha: sha("a"),
      head_sha: sha("c"),
      commits: [%Report.Pushed.Commit{sha: sha("c"), subject: "Work"}],
      rescue_branch: nil
    }

    assert :ok = Runs.pushed(ctx.dctx, report)
    assert %Run{push_status: :pushed, head_sha: head} = Repo.reload!(run)
    assert head == sha("c")
    assert_enqueued(worker: RecordBranch, args: %{run_id: run.id})

    # The same report again is accepted without a write.
    assert :ok = Runs.pushed(ctx.dctx, report)
  end

  test "a conflict push of a local run enqueues no branch record", ctx do
    {repo, project} = bound(ctx)
    task = task_fixture(ctx.alice_scope, project.key)
    branch = "hm/#{ctx.workspace.id}/#{String.downcase(task.ident)}"

    run =
      run_fixture(ctx.agent, %{
        task_id: task.id,
        status: :running,
        daemon_id: ctx.daemon.id,
        claimed_at: DateTime.utc_now(),
        local_repository_id: repo.id,
        branch: branch
      })

    assert :ok =
             Runs.pushed(ctx.dctx, %Report.Pushed{
               run_id: run.id,
               branch: branch,
               base_sha: sha("a"),
               head_sha: sha("c"),
               commits: [],
               rescue_branch: "#{branch}-run-#{run.id}"
             })

    assert Repo.reload!(run).push_status == :conflict
    refute_enqueued(worker: RecordBranch)
  end
end
