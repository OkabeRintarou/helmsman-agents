defmodule Helmsman.E2E.AutopilotSnapshotTest do
  # add-autopilots 9.2: a run-only autopilot in a project bound to a local
  # repository runs in a read-only checkout (protocol 6, decision 13). The
  # fake CLI writes and commits there; afterwards the checkout is gone and
  # neither the user's repository nor the daemon's cache has anything new.
  # Run with `mix test --only e2e test/e2e/autopilot_snapshot_test.exs`.
  use ExUnit.Case, async: false

  @moduletag :e2e
  if :os.type() != {:unix, :linux} do
    @moduletag skip: "daemon E2E tests require Linux"
  end

  @moduletag timeout: 300_000

  import Ecto.Query
  import Helmsman.AccountsFixtures
  import Helmsman.AgentsFixtures
  import Helmsman.AutopilotsFixtures
  import Helmsman.ProjectsFixtures
  import Helmsman.WorkspacesFixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias Helmsman.{Autopilots, CommittedData, DaemonE2E, GitWorkspaceE2E, Projects, Repo}
  alias Helmsman.Autopilots.Record
  alias Helmsman.Daemons.Runtime
  alias Helmsman.LocalRepositories.LocalRepository
  alias Helmsman.Runs.Run

  setup do
    :ok = Sandbox.mode(Repo, :auto)
    on_exit(fn -> Sandbox.mode(Repo, :manual) end)

    tag = Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
    home = Path.join(System.tmp_dir!(), "helmsman-e2e-snapshot-#{tag}")
    File.mkdir_p!(home)
    unless System.get_env("HELMSMAN_E2E_KEEP"), do: on_exit(fn -> File.rm_rf!(home) end)

    user = Path.join([home, "user", "app"])
    File.mkdir_p!(user)
    GitWorkspaceE2E.git!(user, ["init", "--initial-branch=main"])
    GitWorkspaceE2E.git!(user, ["config", "user.name", "Owner"])
    GitWorkspaceE2E.git!(user, ["config", "user.email", "owner@example.test"])
    File.write!(Path.join(user, "README.md"), "local\n")
    GitWorkspaceE2E.git!(user, ["add", "README.md"])
    GitWorkspaceE2E.git!(user, ["commit", "-m", "initial main"])

    {alice, workspace, scope, project, daemon, token} =
      CommittedData.unboxed(fn ->
        alice = user_fixture(%{email: "snapshot-e2e-#{tag}@test.invalid"})
        workspace = workspace_fixture(alice, %{slug: "snap-#{tag}", name: "Snapshot #{tag}"})
        scope = workspace_scope_fixture(alice, workspace)
        project = project_fixture(scope)
        {daemon, token} = daemon_fixture(alice, %{workspace_ids: [workspace.id]})
        {alice, workspace, scope, project, daemon, token}
      end)

    on_exit(fn -> CommittedData.delete_user_data!([alice.id]) end)

    %{
      home: home,
      user: user,
      workspace: workspace,
      scope: scope,
      project: project,
      daemon: daemon,
      token: token
    }
  end

  test "run_only in a local repository: committed in the checkout, nothing kept", ctx do
    machine = Path.join(ctx.home, "machine")
    File.mkdir_p!(machine)
    url = DaemonE2E.start_endpoint()
    DaemonE2E.write_credentials(machine, url, ctx.daemon.id, ctx.token)

    port =
      DaemonE2E.start_e2e_daemon(machine, %{
        heartbeat_interval_ms: 60_000,
        config_check_interval_ms: 200,
        merge_check_interval_ms: 600_000,
        run_worker_opts: %{push_backoff_ms: [0, 0]}
      })

    runtime =
      DaemonE2E.wait_until(port, "the runtime online", fn ->
        case Repo.get_by(Runtime, daemon_id: ctx.daemon.id, workspace_id: ctx.workspace.id) do
          %Runtime{status: "online"} = online -> online
          _ -> nil
        end
      end)

    assert Repo.get!(Helmsman.Daemons.Daemon, ctx.daemon.id).protocol_version >=
             HelmsmanProtocol.snapshot_version()

    local = register_app(ctx, machine, port)
    assert {:ok, _} = Projects.bind_local_repository(ctx.scope, ctx.project.key, local.id)

    before = user_state(ctx.user)
    observed = Path.join(ctx.home, "observed")

    path =
      scenario(ctx, "read", [
        "sh pwd > #{observed}",
        "write changed by the agent",
        "git_commit agent commit",
        "sh git rev-parse HEAD >> #{observed}",
        ~s(json {"type":"result","data":{"text":"Looked around.","success":true}}),
        "exit 0"
      ])

    managed_agent_fixture(ctx.scope, %{
      name: "keel/reader",
      runtime_id: runtime.id,
      access: "workspace",
      custom_args: [path]
    })

    view =
      autopilot_fixture(ctx.scope, %{
        name: "read-the-code",
        agent: "keel/reader",
        mode: "run_only",
        project: ctx.project.key,
        instructions: "Read the code."
      })

    assert {:ok, %Record{status: :started} = record} = Autopilots.run_now(ctx.scope, view.id)

    run =
      DaemonE2E.wait_until(port, "run #{record.run_id} ended", fn ->
        run = Repo.get!(Run, record.run_id)
        run.status in Run.ended_statuses() && run
      end)

    assert %Run{status: :succeeded, task_id: nil, push_status: :none, branch: nil} = run

    assert %Record{status: :succeeded, result: "Looked around."} =
             DaemonE2E.wait_until(port, "record settled", fn ->
               Oban.drain_queue(queue: :autopilots)
               record = Repo.get!(Record, record.id)
               record.status != :started && record
             end)

    checkout = Path.join([machine, "runs", Integer.to_string(run.id), "checkout"])
    assert [cwd, agent_head] = String.split(File.read!(observed), "\n", trim: true)
    assert Path.expand(cwd) == Path.expand(checkout)

    DaemonE2E.wait_until(port, "checkout removed", fn -> not File.exists?(checkout) end)

    assert user_state(ctx.user) == before
    assert {_, status} = System.cmd("git", ["-C", ctx.user, "cat-file", "-e", agent_head])
    assert status != 0

    cache = Path.join([machine, "repos", "local", "app.git"])
    assert GitWorkspaceE2E.git!(cache, ["for-each-ref", "refs/heads"]) == ""

    assert GitWorkspaceE2E.git!(cache, ["worktree", "list", "--porcelain"]) =~
             ~r/\Aworktree [^\n]+\nbare\n*\z/

    assert Repo.aggregate(from(r in Record, where: r.autopilot_id == ^view.id), :count) == 1
  end

  # `helmsman repos add` while the daemon runs; the daemon reports it with `sync`.
  defp register_app(ctx, machine, port) do
    {output, status} =
      System.cmd(
        "mix",
        [
          "helmsman",
          "repos",
          "add",
          ctx.user,
          "--name",
          "app",
          "--workspace",
          ctx.workspace.slug
        ],
        cd: DaemonE2E.daemon_dir(),
        env: [{"MIX_ENV", "test"}, {"HELMSMAN_HOME", machine}],
        stderr_to_stdout: true
      )

    assert status == 0, output

    DaemonE2E.wait_until(port, "local repository app online", fn ->
      Repo.get_by(LocalRepository,
        daemon_id: ctx.daemon.id,
        workspace_id: ctx.workspace.id,
        name: "app",
        status: "online"
      )
    end)
  end

  defp scenario(ctx, name, lines) do
    path = Path.join(ctx.home, "#{name}.scenario")
    File.write!(path, Enum.join(lines, "\n") <> "\n")
    path
  end

  # Every ref (no task branch is expected either), the checkout and the files.
  defp user_state(user) do
    %{
      head: GitWorkspaceE2E.git!(user, ["symbolic-ref", "HEAD"]),
      refs: GitWorkspaceE2E.git!(user, ["for-each-ref", "--format=%(refname) %(objectname)"]),
      status: GitWorkspaceE2E.git!(user, ["status", "--porcelain", "--untracked-files=all"]),
      worktrees: GitWorkspaceE2E.git!(user, ["worktree", "list", "--porcelain"]),
      config: GitWorkspaceE2E.git!(user, ["config", "--local", "--list"]),
      files: File.ls!(user) |> Enum.sort()
    }
  end
end
