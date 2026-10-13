defmodule Helmsman.E2E.LocalRepositoryTest do
  # add-local-repositories 4.1–4.2: service, daemon (protocol 3), fake CLI and
  # a plain repository in a temporary directory as the user's local repository.
  # Run with `mix test --only e2e`.
  use ExUnit.Case, async: false

  @moduletag :e2e
  @moduletag timeout: 300_000

  import Helmsman.AccountsFixtures
  import Helmsman.AgentsFixtures
  import Helmsman.ProjectsFixtures
  import Helmsman.RunsFixtures
  import Helmsman.WorkspacesFixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias Helmsman.Agents.AgentProfile
  alias Helmsman.CommittedData
  alias Helmsman.DaemonE2E
  alias Helmsman.Daemons.Runtime
  alias Helmsman.GitWorkspaceE2E
  alias Helmsman.LocalRepositories
  alias Helmsman.LocalRepositories.{LocalRepository, TaskLocalBranch}
  alias Helmsman.Projects
  alias Helmsman.Repo
  alias Helmsman.Runs
  alias Helmsman.Runs.{Origin, Run}
  alias Helmsman.Tasks.Task
  alias Helmsman.Tx

  setup do
    :ok = Sandbox.mode(Repo, :auto)
    on_exit(fn -> Sandbox.mode(Repo, :manual) end)

    tag = Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
    home = Path.join(System.tmp_dir!(), "helmsman-e2e-local-#{tag}")
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

    {owner, workspace, scope, project} =
      CommittedData.unboxed(fn ->
        owner = user_fixture(%{email: "local-e2e-#{tag}@test.invalid"})
        workspace = workspace_fixture(owner, %{slug: "local-#{tag}", name: "Local e2e #{tag}"})
        scope = workspace_scope_fixture(owner, workspace)
        {owner, workspace, scope, project_fixture(scope)}
      end)

    endpoint_url = DaemonE2E.start_endpoint()
    on_exit(fn -> CommittedData.delete_user_data!([owner.id]) end)

    %{
      tag: tag,
      home: home,
      user: user,
      owner: owner,
      workspace: workspace,
      scope: scope,
      project: project,
      endpoint_url: endpoint_url
    }
  end

  test "4.1 delivery to the user's repository, merge detection and a new delivery", ctx do
    machine = start_machine(ctx, 1)
    local = register_app(ctx, machine)
    assert {:ok, _project} = Projects.bind_local_repository(ctx.scope, ctx.project.key, local.id)
    before = snapshot(ctx.user)

    agent =
      make_agent(ctx, machine.runtime, scenario(ctx, "first", ["write first", result("first")]))

    task = task_fixture(ctx.scope, ctx.project.key, %{assignee: agent.name})
    [run] = runs_of(task.id)
    branch = "hm/#{ctx.workspace.id}/#{String.downcase(task.ident)}"

    assert %Run{status: :succeeded, push_status: :pushed, branch: ^branch, head_sha: head} =
             wait_status(machine.port, run, "first local delivery")

    assert user_ref(ctx.user, branch) == head
    assert snapshot(ctx.user) == before
    assert GitWorkspaceE2E.git!(ctx.user, ["show", "#{branch}:hello.txt"]) == "first\n"

    Oban.drain_queue(queue: :runs)
    assert %TaskLocalBranch{state: "open", head_sha: ^head, branch: ^branch} = local_branch(task)

    GitWorkspaceE2E.git!(ctx.user, ["merge", "--no-ff", "-m", "review #{task.ident}", branch])
    assert :ok = LocalRepositories.refresh(ctx.scope, task.ident)

    assert %TaskLocalBranch{state: "merged", head_sha: ^head, merged_by_id: nil} =
             DaemonE2E.wait_until(
               machine.port,
               "merge detected",
               fn ->
                 branch_row = local_branch(task)
                 if branch_row.state == "merged", do: branch_row
               end,
               10_000
             )

    update_agent(agent, machine.runtime, scenario(ctx, "second", ["write second", result("2")]))
    second = enqueue(ctx, task, agent)

    assert %Run{status: :succeeded, push_status: :pushed, head_sha: second_head} =
             wait_status(machine.port, second, "second local delivery")

    assert user_ref(ctx.user, branch) == second_head
    Oban.drain_queue(queue: :runs)
    assert %TaskLocalBranch{state: "open", head_sha: ^second_head} = local_branch(task)
  end

  test "4.2 a runtime on another machine fails with workspace_prepare", ctx do
    first = start_machine(ctx, 1)
    local = register_app(ctx, first)
    assert {:ok, _project} = Projects.bind_local_repository(ctx.scope, ctx.project.key, local.id)
    second = start_machine(ctx, 2)
    before = snapshot(ctx.user)

    agent = make_agent(ctx, second.runtime, scenario(ctx, "other", ["write x", result("x")]))
    task = task_fixture(ctx.scope, ctx.project.key, %{assignee: agent.name})
    [run] = runs_of(task.id)

    assert %Run{status: :failed, failure_reason: :workspace_prepare, error: error} =
             wait_status(second.port, run, "claim on another machine")

    assert error =~ "This project's repository app is on #{local_daemon_name(local)}"
    assert error =~ "the agent's runtime is on another machine"
    assert snapshot(ctx.user) == before
    refute File.exists?(Path.join([second.home, "repos", "local"]))
  end

  defp start_machine(ctx, index) do
    {daemon, token} = daemon_fixture(ctx.owner, %{workspace_ids: [ctx.workspace.id]})
    home = Path.join(ctx.home, "machine-#{index}")
    File.mkdir_p!(home)
    DaemonE2E.write_credentials(home, ctx.endpoint_url, daemon.id, token)

    port =
      DaemonE2E.start_e2e_daemon(home, %{
        heartbeat_interval_ms: 60_000,
        config_check_interval_ms: 200,
        merge_check_interval_ms: 600_000,
        run_worker_opts: %{push_backoff_ms: [0, 0]}
      })

    runtime =
      DaemonE2E.wait_until(port, "runtime #{daemon.id} online", fn ->
        case Repo.get_by(Runtime, daemon_id: daemon.id, workspace_id: ctx.workspace.id) do
          %Runtime{status: "online"} = online -> online
          _ -> nil
        end
      end)

    DaemonE2E.wait_until(port, "served workspaces recorded", fn ->
      File.exists?(Path.join([home, "state", "workspaces.json"]))
    end)

    %{daemon: daemon, home: home, port: port, runtime: runtime}
  end

  # `helmsman repos add` while the daemon runs; the daemon reports it with `sync`.
  defp register_app(ctx, machine) do
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
        env: [{"MIX_ENV", "test"}, {"HELMSMAN_HOME", machine.home}],
        stderr_to_stdout: true
      )

    assert status == 0, output
    assert output =~ "Added local repository app"

    DaemonE2E.wait_until(machine.port, "local repository app online", fn ->
      Repo.get_by(LocalRepository,
        daemon_id: machine.daemon.id,
        workspace_id: ctx.workspace.id,
        name: "app",
        status: "online"
      )
    end)
  end

  defp local_daemon_name(%LocalRepository{daemon_id: id}),
    do: Repo.get!(Helmsman.Daemons.Daemon, id).name

  defp make_agent(ctx, runtime, scenario) do
    managed_agent_fixture(ctx.scope, %{
      name: "keel/dev",
      runtime_id: runtime.id,
      custom_args: [scenario]
    })

    agent_actor(ctx.workspace, "keel/dev")
  end

  defp update_agent(agent, runtime, scenario) do
    profile = Repo.get_by!(AgentProfile, actor_id: agent.id)
    Repo.update!(Ecto.Changeset.change(profile, runtime_id: runtime.id, custom_args: [scenario]))
  end

  defp enqueue(ctx, task, agent) do
    profile = Repo.get_by!(AgentProfile, actor_id: agent.id)
    task = Repo.get!(Task, task.id)

    {:ok, outcome} =
      Tx.run(fn ->
        Runs.enqueue(
          Origin.from_scope(ctx.scope),
          %{agent: agent, profile: profile, task: task},
          %{kind: :manual, instructions: "continue E2E run"}
        )
      end)

    outcome.run_id
  end

  defp scenario(ctx, name, lines) do
    path = Path.join(ctx.home, "#{name}.scenario")
    File.write!(path, Enum.join(lines ++ ["exit 0"], "\n") <> "\n")
    path
  end

  defp result(text), do: ~s(json {"type":"result","data":{"text":"#{text}","success":true}})

  defp wait_status(port, run, label) do
    id = if match?(%Run{}, run), do: run.id, else: run

    DaemonE2E.wait_until(
      port,
      fn -> "#{label} (#{inspect(Repo.get!(Run, id), limit: :infinity)})" end,
      fn ->
        run = Repo.get!(Run, id)
        if run.status in [:succeeded, :failed, :cancelled], do: run
      end
    )
  end

  defp local_branch(task), do: Repo.get_by!(TaskLocalBranch, task_id: task.id)

  defp user_ref(user, branch),
    do: GitWorkspaceE2E.git!(user, ["rev-parse", "refs/heads/#{branch}"]) |> String.trim()

  # Everything the daemon must leave alone in the user's repository.
  defp snapshot(user) do
    refs =
      user
      |> GitWorkspaceE2E.git!(["for-each-ref", "--format=%(refname) %(objectname)"])
      |> String.split("\n", trim: true)
      |> Enum.reject(&String.starts_with?(&1, "refs/heads/hm/"))

    %{
      head: GitWorkspaceE2E.git!(user, ["symbolic-ref", "HEAD"]),
      head_sha: GitWorkspaceE2E.git!(user, ["rev-parse", "HEAD"]),
      status: GitWorkspaceE2E.git!(user, ["status", "--porcelain", "--untracked-files=all"]),
      index: GitWorkspaceE2E.git!(user, ["ls-files", "-s"]),
      refs: refs,
      config: GitWorkspaceE2E.git!(user, ["config", "--local", "--list"]),
      files: File.ls!(user) |> Enum.sort()
    }
  end
end
