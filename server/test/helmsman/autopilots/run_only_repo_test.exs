defmodule Helmsman.Autopilots.RunOnlyRepoTest do
  # add-autopilots 5.3: the repository of a run-only run (decision 13;
  # specs/autopilot-execution "仅运行模式的仓库"). The run description of
  # a read-only checkout needs protocol 6 (5.4); here the resolution, the
  # tokens and the refusals.
  use Helmsman.DataCase, async: true
  use Oban.Testing, repo: Helmsman.Repo

  @moduletag :capture_log

  import Helmsman.AutopilotsFixtures
  import Helmsman.GitHubFixtures
  import Helmsman.LocalRepositoriesFixtures
  import Helmsman.ProjectsFixtures
  import Helmsman.RunsFixtures

  alias Helmsman.Autopilots
  alias Helmsman.Runs
  alias Helmsman.Runs.{GitRepo, LocalRepo, Run}
  alias HelmsmanProtocol.Report

  setup do
    ctx = autopilots_fixture()
    installation = installation_fixture(ctx.workspace)
    repository = repository_fixture(installation, %{owner: "acme", name: "app"})
    bind_repository(ctx.project, repository)
    other = project_fixture(ctx.alice_scope, %{key: "KEEL"})
    other_repo = repository_fixture(installation, %{owner: "acme", name: "other"})
    bind_repository(other, other_repo)

    view =
      autopilot_fixture(ctx.alice_scope, %{
        mode: "run_only",
        project: ctx.project.key,
        instructions: "Read the code."
      })

    daemon = daemon_of(ctx.agent)

    Map.merge(ctx, %{
      installation: installation,
      repository: repository,
      other: other,
      view: view,
      daemon: daemon
    })
  end

  defp queued(ctx) do
    {:ok, record} = Autopilots.run_now(ctx.alice_scope, ctx.view.id)
    Repo.get!(Run, record.run_id)
  end

  defp dctx(ctx, protocol), do: %{daemon_ctx(ctx.daemon) | protocol: protocol}

  test "the frozen project's repository, read-only: base branch, no task branch", ctx do
    run = queued(ctx)
    # Changing the project afterwards does not move the run.
    {:ok, _} =
      Autopilots.update(ctx.alice_scope, ctx.view.id, %{project: "KEEL", instructions: "Other."})

    stub_push_tokens()
    tokens = Runs.prefetch_push_tokens(daemon_ctx(ctx.daemon))
    assert_received {:push_token_request, _id, body}

    assert body == %{
             "repository_ids" => [ctx.repository.github_id],
             "permissions" => %{"contents" => "read"}
           }

    assert Map.keys(tokens) == [{:read, ctx.repository.id}]

    assert {:ok, repo} = GitRepo.resolve(run, nil, tokens)
    assert repo.repository.id == ctx.repository.id

    assert {repo.mode, repo.branch, repo.base_branch, repo.rescue_branches} ==
             {:snapshot, nil, "main", []}

    # Without a token it waits.
    assert GitRepo.resolve(run, nil, %{}) == :no_token
  end

  test "no project, or an unbound one: no repository", ctx do
    view = autopilot_fixture(ctx.alice_scope, %{mode: "run_only", project: nil})
    {:ok, record} = Autopilots.run_now(ctx.alice_scope, view.id)
    run = Repo.get!(Run, record.run_id)
    assert GitRepo.resolve(run, nil, %{}) == :none
    assert LocalRepo.resolve(run, nil, ctx.daemon, 6) == :none

    unbound = project_fixture(ctx.alice_scope, %{key: "FREE"})
    view = autopilot_fixture(ctx.alice_scope, %{mode: "run_only", project: unbound.key})
    {:ok, record} = Autopilots.run_now(ctx.alice_scope, view.id)
    assert GitRepo.resolve(Repo.get!(Run, record.run_id), nil, %{}) == :none
  end

  test "an old daemon: failed / workspace_prepare saying to upgrade; record run_failed", ctx do
    run = queued(ctx)
    stub_push_tokens()

    assert {:ok, []} = Runs.claim(dctx(ctx, 5), "http://localhost:4000", %{})

    run = Repo.get!(Run, run.id)
    assert {run.status, run.failure_reason} == {:failed, :workspace_prepare}
    assert run.error =~ "too old to run autopilots in a repository; upgrade it"
    assert run.error =~ ctx.daemon.name

    {:ok, _} = Autopilots.settle(ctx.view.id)
    [record] = records_of(ctx.view)
    assert {record.status, record.reason} == {:failed, "run_failed"}
  end

  test "a local repository: read-only on its machine only", ctx do
    repo =
      local_repository_fixture(ctx.workspace, ctx.daemon, %{name: "app", default_branch: "main"})

    local = project_fixture(ctx.alice_scope, %{key: "LOC"})
    bind_local(local, repo)
    view = autopilot_fixture(ctx.alice_scope, %{mode: "run_only", project: "LOC"})
    {:ok, record} = Autopilots.run_now(ctx.alice_scope, view.id)
    run = Repo.get!(Run, record.run_id)

    assert {:ok, %{kind: :local, mode: :snapshot, branch: nil, base_branch: "main"}} =
             LocalRepo.resolve(run, nil, ctx.daemon, 6)

    {other_daemon, _} = Helmsman.AgentsFixtures.daemon_fixture(ctx.alice)
    assert {:unavailable, message} = LocalRepo.resolve(run, nil, other_daemon, 6)
    assert message =~ "on another machine"
  end

  test "a push report of a read-only checkout is refused; the token renewal is read-only", ctx do
    run = queued(ctx)

    run =
      Repo.update!(
        Ecto.Changeset.change(run,
          status: :running,
          daemon_id: ctx.daemon.id,
          repository_id: ctx.repository.id,
          claimed_at: DateTime.utc_now()
        )
      )

    {:ok, report} =
      Report.Pushed.new(%{
        run_id: run.id,
        branch: "hm/x",
        base_sha: String.duplicate("0", 40),
        head_sha: String.duplicate("a", 40),
        commits: [],
        rescue_branch: nil
      })

    assert Runs.pushed(daemon_ctx(ctx.daemon), report) == {:error, :wrong_state}
    assert %Run{push_status: :none, pushed_at: nil} = Repo.get!(Run, run.id)

    stub_push_tokens()
    assert {:ok, %{token: _}} = Runs.git_token(daemon_ctx(ctx.daemon), run.id)
    assert_received {:push_token_request, _id, %{"permissions" => %{"contents" => "read"}}}
  end
end
