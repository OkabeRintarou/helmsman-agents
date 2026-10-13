defmodule Helmsman.Runs.SpecSnapshotTest do
  # add-autopilots 5.4: the run description of a read-only checkout under
  # protocol 6 (decision 13; specs/daemon-protocol "运行描述中仓库的只读检出").
  use Helmsman.DataCase, async: true

  @moduletag :capture_log

  import Helmsman.AutopilotsFixtures
  import Helmsman.GitHubFixtures
  import Helmsman.LocalRepositoriesFixtures
  import Helmsman.ProjectsFixtures
  import Helmsman.RunsFixtures

  alias Helmsman.Autopilots
  alias Helmsman.Runs
  alias Helmsman.Runs.{Run, Spec}
  alias HelmsmanProtocol.{Messages, Reply, RunSpec}

  @base_url "http://localhost:4000"

  setup do
    ctx = autopilots_fixture()
    installation = installation_fixture(ctx.workspace)
    repository = repository_fixture(installation, %{owner: "acme", name: "app"})
    bind_repository(ctx.project, repository)
    view = autopilot_fixture(ctx.alice_scope, %{mode: "run_only", project: ctx.project.key})
    Map.merge(ctx, %{repository: repository, view: view, daemon: daemon_of(ctx.agent)})
  end

  defp run_now(ctx, view) do
    {:ok, record} = Autopilots.run_now(ctx.alice_scope, view.id)
    Repo.get!(Run, record.run_id)
  end

  defp dctx(ctx, protocol), do: %{daemon_ctx(ctx.daemon) | protocol: protocol}

  defp claim_reply(specs), do: %Reply.Claim{runs: specs}

  test "protocol 6: a GitHub snapshot carries mode and no task branch", ctx do
    assert HelmsmanProtocol.snapshot_version() == 6
    assert Autopilots.snapshot_version() == HelmsmanProtocol.snapshot_version()
    run = run_now(ctx, ctx.view)
    stub_push_tokens()
    tokens = Runs.prefetch_push_tokens(dctx(ctx, 6))

    assert {:ok, [%RunSpec{run_id: run_id, task: nil, repo: repo} = spec]} =
             Runs.claim(dctx(ctx, 6), @base_url, tokens)

    assert run_id == run.id

    assert %RunSpec.Repo{
             kind: :github,
             mode: :snapshot,
             branch: nil,
             rescue_branches: [],
             base_branch: "main"
           } = repo

    assert repo.github_repository_id == ctx.repository.github_id

    assert {:ok, %{"runs" => [wire]}} = Messages.encode_reply("claim", claim_reply([spec]), 6)

    assert %{"mode" => "snapshot", "branch" => nil, "rescue_branches" => [], "kind" => "github"} =
             wire["repo"]

    assert {:ok, ^spec} = RunSpec.from_wire(wire)

    # A version 5 daemon can never receive it: encoding refuses.
    assert {:error, {:not_in_version, 5}} =
             Messages.encode_reply("claim", claim_reply([spec]), 5)
  end

  test "protocol 6: a local repository snapshot names the repository only", ctx do
    local =
      local_repository_fixture(ctx.workspace, ctx.daemon, %{name: "app", default_branch: "main"})

    project = project_fixture(ctx.alice_scope, %{key: "LOC"})
    bind_local(project, local)
    view = autopilot_fixture(ctx.alice_scope, %{mode: "run_only", project: "LOC"})
    run = run_now(ctx, view)

    assert {:ok, specs} = Runs.claim(dctx(ctx, 6), @base_url, %{})
    assert %RunSpec{repo: repo} = spec = Enum.find(specs, &(&1.run_id == run.id))

    assert %RunSpec.Repo{kind: :local, mode: :snapshot, name: "app", branch: nil} = repo
    assert {:ok, %{"runs" => [wire]}} = Messages.encode_reply("claim", claim_reply([spec]), 6)
    assert %{"mode" => "snapshot", "branch" => nil, "git_token" => nil} = wire["repo"]
  end

  test "protocol 5: the claim fails the run before any description is built", ctx do
    run = run_now(ctx, ctx.view)
    stub_push_tokens()

    assert {:ok, []} = Runs.claim(dctx(ctx, 5), @base_url, %{})
    assert %Run{status: :failed, failure_reason: :workspace_prepare} = Repo.get!(Run, run.id)
  end

  test "a task run keeps task mode; encoded for protocol 5 it has no mode key", ctx do
    task = task_fixture(ctx.alice_scope, ctx.project.key, %{title: "Add login"})
    assign = trigger("assign", ctx.workspace, ctx.alice, ctx.agent)
    run = run_fixture(ctx.agent, %{status: :claimed, task_id: task.id, triggers: [assign]})
    branch = "hm/#{ctx.workspace.id}/#{String.downcase(task.ident)}"

    repo = %{
      repository: ctx.repository,
      base_branch: "main",
      branch: branch,
      rescue_branches: [],
      token: %{token: "ghs_task_token", expires_at: DateTime.utc_now()}
    }

    assert {:ok, %RunSpec{repo: %RunSpec.Repo{mode: :task, branch: ^branch}} = spec} =
             Spec.build(run, "hmr_" <> String.duplicate("a", 52), @base_url, repo)

    assert {:ok, %{"runs" => [%{"repo" => v6}]}} =
             Messages.encode_reply("claim", claim_reply([spec]), 6)

    assert v6["mode"] == "task"

    assert {:ok, %{"runs" => [%{"repo" => v5}]}} =
             Messages.encode_reply("claim", claim_reply([spec]), 5)

    refute Map.has_key?(v5, "mode")
    assert v5["branch"] == branch
  end
end
