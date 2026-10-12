defmodule Helmsman.Runs.ClaimRepoTest do
  # add-daemon-git-workspace 1.2: the repository of the run description and
  # the push tokens fetched before the claim (decision 2).
  use Helmsman.DataCase, async: true
  use Oban.Testing, repo: Helmsman.Repo

  @moduletag :capture_log

  import Helmsman.GitHubFixtures
  import Helmsman.ProjectsFixtures
  import Helmsman.RunsFixtures

  alias Helmsman.Runs
  alias Helmsman.Runs.Run
  alias Helmsman.Runs.Workers.Retry
  alias Helmsman.Workspaces.Workspace
  alias HelmsmanProtocol.RunSpec

  @base_url "http://localhost:4000"

  setup do
    ctx = dispatch_fixture()
    installation = installation_fixture(ctx.workspace)
    repository = repository_fixture(installation, %{owner: "acme", name: "app"})
    Map.merge(ctx, %{daemon: daemon_of(ctx.agent), installation: installation, repo: repository})
  end

  defp claim(ctx) do
    dctx = daemon_ctx(ctx.daemon)
    Runs.claim(dctx, @base_url, Runs.prefetch_push_tokens(dctx))
  end

  defp queued_task_run(ctx, project, attrs \\ %{}) do
    task = task_fixture(ctx.alice_scope, project.key)
    {task, run_fixture(ctx.agent, Map.merge(%{task_id: task.id}, attrs))}
  end

  defp reload(run), do: Repo.get!(Run, run.id)

  test "a bound repository (scenario): URL, GitHub ID, branches and a push token", ctx do
    stub_push_tokens()
    bind_repository(ctx.project, ctx.repo)
    {task, run} = queued_task_run(ctx, ctx.project)

    # The branch uses the immutable workspace ID, not the slug.
    Repo.update_all(from(w in Workspace, where: w.id == ^ctx.workspace.id),
      set: [slug: "renamed-#{System.unique_integer([:positive])}"]
    )

    assert {:ok, [%RunSpec{repo: repo} = spec]} = claim(ctx)
    branch = "hm/#{ctx.workspace.id}/#{String.downcase(task.ident)}"

    assert %RunSpec.Repo{
             clone_url: "https://github.com/acme/app.git",
             base_branch: "main",
             rescue_branches: [],
             git_token: "ghs_push_1",
             git_token_expires_at: %DateTime{}
           } = repo

    assert repo.github_repository_id == ctx.repo.github_id
    assert repo.branch == branch
    assert_received {:push_token_request, installation_id, body}
    assert installation_id == ctx.installation.installation_id

    assert body == %{
             "repository_ids" => [ctx.repo.github_id],
             "permissions" => %{"contents" => "write"}
           }

    assert %Run{status: :claimed, branch: ^branch} = claimed = reload(run)
    assert claimed.repository_id == ctx.repo.id
    assert spec.prompt =~ "a git worktree of acme/app on branch #{branch} (based on main)"
    refute spec.prompt =~ "ghs_push_1"
  end

  test "a project's base branch wins over the default branch", ctx do
    stub_push_tokens()
    bind_repository(ctx.project, ctx.repo, "develop")
    queued_task_run(ctx, ctx.project)

    assert {:ok, [%RunSpec{repo: %RunSpec.Repo{base_branch: "develop"}}]} = claim(ctx)
  end

  test "an unbound project: no repository, the scratch directory as before", ctx do
    counter = stub_push_tokens()
    {_task, run} = queued_task_run(ctx, ctx.project)

    assert {:ok, [%RunSpec{repo: nil, prompt: prompt}]} = claim(ctx)
    assert prompt =~ "This project has no repository."
    assert %Run{status: :claimed, repository_id: nil, branch: nil} = reload(run)
    assert :counters.get(counter, 1) == 0
  end

  test "the same task in two workspaces gets two branches (scenario)", ctx do
    stub_push_tokens()
    other = dispatch_fixture()
    other_installation = installation_fixture(other.workspace)

    other_repo =
      repository_fixture(other_installation, %{
        github_id: ctx.repo.github_id,
        owner: "acme",
        name: "app"
      })

    branches =
      for {c, repository} <- [
            {ctx, ctx.repo},
            {Map.put(other, :daemon, daemon_of(other.agent)), other_repo}
          ] do
        project = project_fixture(c.alice_scope, %{key: "BOS"})
        bind_repository(project, repository)
        {task, _run} = queued_task_run(c, project)
        assert task.ident == "BOS-1"
        assert {:ok, [%RunSpec{repo: %{branch: branch}}]} = claim(c)
        branch
      end

    assert branches == ["hm/#{ctx.workspace.id}/bos-1", "hm/#{other.workspace.id}/bos-1"]
  end

  test "GitHub unavailable (scenario): the run stays queued, others are claimed", ctx do
    stub_push_tokens(fail: :all)
    bind_repository(ctx.project, ctx.repo)
    {_task, bound} = queued_task_run(ctx, ctx.project, %{priority: 3})
    free = run_fixture(ctx.agent)

    assert {:ok, [%RunSpec{run_id: id, repo: nil}]} = claim(ctx)
    assert id == free.id
    assert %Run{status: :queued, repository_id: nil, daemon_id: nil} = reload(bound)
  end

  test "an archived repository (scenario): failed workspace_prepare, no retry", ctx do
    counter = stub_push_tokens()
    Repo.update!(Ecto.Changeset.change(ctx.repo, archived: true))
    bind_repository(ctx.project, ctx.repo)
    {_task, run} = queued_task_run(ctx, ctx.project)

    assert claim(ctx) == {:ok, []}
    assert %Run{status: :failed, failure_reason: :workspace_prepare, error: error} = reload(run)
    assert error =~ "Repository acme/app is not available"
    assert :counters.get(counter, 1) == 0
    refute_enqueued(worker: Retry)
  end

  test "a disconnected installation makes the repository unavailable", ctx do
    stub_push_tokens()

    Repo.update!(
      Ecto.Changeset.change(ctx.installation, disconnected_at: DateTime.utc_now(:second))
    )

    bind_repository(ctx.project, ctx.repo)
    {_task, run} = queued_task_run(ctx, ctx.project)

    assert claim(ctx) == {:ok, []}
    assert %Run{status: :failed, failure_reason: :workspace_prepare} = reload(run)
  end

  test "rescue branches (scenario): same repository only, deduplicated, by run", ctx do
    stub_push_tokens()
    bind_repository(ctx.project, ctx.repo)
    other_repo = repository_fixture(ctx.installation)
    task = task_fixture(ctx.alice_scope, ctx.project.key)
    branch = "hm/#{ctx.workspace.id}/#{String.downcase(task.ident)}"

    conflict = fn repository, rescue_branch ->
      run_fixture(ctx.agent, %{
        task_id: task.id,
        status: :failed,
        failure_reason: :push_conflict,
        finished_at: DateTime.utc_now(),
        repository_id: repository.id,
        branch: branch,
        push_status: :conflict,
        base_sha: String.duplicate("a", 40),
        head_sha: String.duplicate("b", 40),
        rescue_branch: rescue_branch,
        pushed_at: DateTime.utc_now()
      })
    end

    first = conflict.(ctx.repo, "#{branch}-run-31")
    conflict.(other_repo, "#{branch}-run-32")
    conflict.(ctx.repo, "#{branch}-run-33")
    conflict.(ctx.repo, "#{branch}-run-31")
    assert first.rescue_branch == "#{branch}-run-31"

    run_fixture(ctx.agent, %{task_id: task.id})

    assert {:ok, [%RunSpec{repo: repo, prompt: prompt}]} = claim(ctx)
    assert repo.rescue_branches == ["#{branch}-run-31", "#{branch}-run-33"]
    assert prompt =~ "Before this run Helmsman merged #{branch}-run-31, #{branch}-run-33 into"
  end

  test "push tokens are prefetched for at most 20 repositories, oldest runs first", ctx do
    counter = stub_push_tokens()
    now = DateTime.utc_now()

    repos =
      for i <- 1..21 do
        project = project_fixture(ctx.alice_scope)
        repository = repository_fixture(ctx.installation)
        bind_repository(project, repository)

        queued_task_run(ctx, project, %{
          inserted_at: DateTime.add(now, i - 60, :second),
          not_before: DateTime.add(now, -120, :second)
        })

        repository
      end

    tokens = Runs.prefetch_push_tokens(daemon_ctx(ctx.daemon))
    assert map_size(tokens) == 20
    assert :counters.get(counter, 1) == 20

    assert Map.keys(tokens) |> Enum.sort() ==
             repos |> Enum.take(20) |> Enum.map(& &1.id) |> Enum.sort()
  end

  test "nothing to prefetch for a reauthorized daemon or without queued runs", ctx do
    counter = stub_push_tokens()
    bind_repository(ctx.project, ctx.repo)
    dctx = daemon_ctx(ctx.daemon)

    assert Runs.prefetch_push_tokens(dctx) == %{}
    queued_task_run(ctx, ctx.project)
    assert Runs.prefetch_push_tokens(%{dctx | auth_epoch: dctx.auth_epoch + 1}) == %{}
    assert :counters.get(counter, 1) == 0
  end

  test "no HTTP inside the claim transaction", ctx do
    counter = stub_push_tokens()
    bind_repository(ctx.project, ctx.repo)
    queued_task_run(ctx, ctx.project)
    dctx = daemon_ctx(ctx.daemon)

    tokens = Runs.prefetch_push_tokens(dctx)
    assert :counters.get(counter, 1) == 1
    assert {:ok, [%RunSpec{repo: %RunSpec.Repo{}}]} = Runs.claim(dctx, @base_url, tokens)
    assert :counters.get(counter, 1) == 1
    refute_received :http_in_transaction

    # A request inside a transaction would be caught by the stub.
    assert_raise RuntimeError, ~r/inside a database transaction/, fn ->
      Repo.transact(fn ->
        {:ok, Helmsman.GitHub.push_token(repository_fixture(ctx.installation))}
      end)
    end

    assert_received :http_in_transaction
  end
end
