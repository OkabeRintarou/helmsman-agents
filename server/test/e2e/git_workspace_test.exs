defmodule Helmsman.E2E.GitWorkspaceTest do
  # add-daemon-git-workspace 3.1–3.4: service, daemon, fake CLI and local Git
  # remote exercise the real push and recovery path. Run with `mix test --only e2e`.
  use ExUnit.Case, async: false

  @moduletag :e2e
  @moduletag timeout: 300_000

  import Ecto.Query
  import Helmsman.AccountsFixtures
  import Helmsman.AgentsFixtures
  import Helmsman.GitHubFixtures
  import Helmsman.ProjectsFixtures
  import Helmsman.RunsFixtures
  import Helmsman.WorkspacesFixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias Helmsman.Agents.AgentProfile
  alias Helmsman.CommittedData
  alias Helmsman.DaemonE2E
  alias Helmsman.Daemons.{Daemon, Runtime}
  alias Helmsman.GitWorkspaceE2E
  alias Helmsman.Repo
  alias Helmsman.Runs
  alias Helmsman.Runs.{Origin, Run}
  alias Helmsman.Runs.Workers.Sweep
  alias Helmsman.Tasks.Task
  alias Helmsman.Tx

  setup do
    :ok = Sandbox.mode(Repo, :auto)
    on_exit(fn -> Sandbox.mode(Repo, :manual) end)

    tag = Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
    home = Path.join(System.tmp_dir!(), "helmsman-e2e-git-#{tag}")
    git_root = Path.join(home, "github")
    File.mkdir_p!(home)
    remote = GitWorkspaceE2E.create_repository(git_root)
    unless System.get_env("HELMSMAN_E2E_KEEP"), do: on_exit(fn -> File.rm_rf!(home) end)

    previous_github = Application.fetch_env(:helmsman, Helmsman.GitHub)

    Application.put_env(
      :helmsman,
      Helmsman.GitHub,
      Keyword.put(
        Application.get_env(:helmsman, Helmsman.GitHub, []),
        :web_url,
        "file://#{git_root}"
      )
    )

    on_exit(fn ->
      case previous_github do
        {:ok, config} -> Application.put_env(:helmsman, Helmsman.GitHub, config)
        :error -> Application.delete_env(:helmsman, Helmsman.GitHub)
      end
    end)

    {owner, workspace, scope, project, installation, repository, daemon, token} =
      CommittedData.unboxed(fn ->
        owner = user_fixture(%{email: "git-e2e-#{tag}@test.invalid"})
        workspace = workspace_fixture(owner, %{slug: "git-e2e-#{tag}", name: "Git e2e #{tag}"})
        scope = workspace_scope_fixture(owner, workspace)
        project = project_fixture(scope)
        installation = installation_fixture(workspace)

        repository =
          repository_fixture(installation, %{
            owner: "acme",
            name: "app",
            default_branch: "main"
          })

        :ok = bind_repository(project, repository)
        {daemon, token} = daemon_fixture(owner, %{workspace_ids: [workspace.id]})
        {owner, workspace, scope, project, installation, repository, daemon, token}
      end)

    :ok = Req.Test.set_req_test_to_shared(self())
    on_exit(fn -> Req.Test.set_req_test_to_private() end)
    _token_counter = stub_push_tokens()
    endpoint_url = DaemonE2E.start_endpoint()
    on_exit(fn -> CommittedData.delete_user_data!([owner.id]) end)

    %{
      tag: tag,
      home: home,
      git_root: git_root,
      remote: remote,
      owner: owner,
      workspace: workspace,
      scope: scope,
      project: project,
      installation: installation,
      repository: repository,
      daemon: daemon,
      token: token,
      endpoint_url: endpoint_url
    }
  end

  test "3.1 a second machine continues the branch and rescue merge preserves both sides", ctx do
    first = start_machine(ctx, 1, %{heartbeat_interval_ms: 60_000})
    second = start_machine(ctx, 2, %{heartbeat_interval_ms: 60_000})

    agent =
      make_agent(
        ctx,
        first.runtime,
        scenario(ctx.home, "first", ["write first-machine", result("first"), "exit 0"])
      )

    {task, first_run} = assign(ctx, agent)
    branch = task_branch(ctx, task)

    assert %Run{status: :succeeded, push_status: :pushed} =
             wait_status(first.port, first_run, [:succeeded, :failed], "first machine push")

    first_run = Repo.get!(Run, first_run.id)
    first_head = GitWorkspaceE2E.head(ctx.remote, branch)
    assert first_run.head_sha == first_head
    assert GitWorkspaceE2E.show(ctx.remote, branch, "hello.txt") == "first-machine\n"

    assert GitWorkspaceE2E.git!(ctx.remote.bare, ["show", "-s", "--format=%an", first_head])
           |> String.trim() == "keel/dev"

    update_agent(
      agent,
      second.runtime,
      scenario(ctx.home, "second", [result("continued"), "exit 0"])
    )

    second_run = enqueue(ctx, task, agent)

    assert %Run{status: :succeeded, push_status: :none} =
             wait_status(
               second.port,
               second_run,
               [:succeeded, :failed],
               "second machine continuation"
             )

    second_worktree = worktree(second.home, ctx.workspace.id, task.ident)
    assert File.read!(Path.join(second_worktree, "hello.txt")) == "first-machine\n"

    barrier = Path.join(ctx.home, "remote-conflict")

    update_agent(
      agent,
      second.runtime,
      scenario(ctx.home, "conflict", [
        "write agent-change",
        "barrier #{barrier}",
        result("conflict"),
        "exit 0"
      ])
    )

    conflicting_run = enqueue(ctx, task, agent)
    await_file(second.port, barrier <> ".ready", "second machine reached conflict barrier")

    external_head =
      GitWorkspaceE2E.push_file(ctx.remote, branch, "external.txt", "external-change\n")

    File.write!(barrier <> ".release", "release")

    conflicting_run =
      wait_status(second.port, conflicting_run, [:succeeded, :failed], "conflicting push")

    assert %Run{status: :failed, failure_reason: :push_conflict, push_status: :conflict} =
             conflicting_run

    assert conflicting_run.rescue_branch == "#{branch}-run-#{conflicting_run.id}"
    rescue_head = GitWorkspaceE2E.head(ctx.remote, conflicting_run.rescue_branch)

    assert GitWorkspaceE2E.show(ctx.remote, conflicting_run.rescue_branch, "hello.txt") ==
             "agent-change\n"

    retry_barrier = Path.join(ctx.home, "rescue-retry")

    update_agent(
      agent,
      second.runtime,
      scenario(ctx.home, "retry", ["barrier #{retry_barrier}", result("merged"), "exit 0"])
    )

    retry_run = manual_retry(ctx, conflicting_run)
    await_file(second.port, retry_barrier <> ".ready", "retry prepared rescue merge")

    retried_worktree = worktree(second.home, ctx.workspace.id, task.ident)
    assert File.read!(Path.join(retried_worktree, "external.txt")) == "external-change\n"
    assert File.read!(Path.join(retried_worktree, "hello.txt")) == "agent-change\n"
    assert_git_ancestor(retried_worktree, first_head)
    assert_git_ancestor(retried_worktree, external_head)
    assert_git_ancestor(retried_worktree, rescue_head)

    File.write!(retry_barrier <> ".release", "release")

    assert %Run{status: :succeeded} =
             wait_status(second.port, retry_run, [:succeeded, :failed], "rescue retry")
  end

  test "3.2 Sweep marks an offline run failed before its late push is recorded", ctx do
    machine = start_machine(ctx, 1, %{heartbeat_interval_ms: 600_000})
    barrier = Path.join(ctx.home, "late-push")

    agent =
      make_agent(
        ctx,
        machine.runtime,
        scenario(ctx.home, "late", [
          "write late-push",
          "barrier #{barrier}",
          result("late"),
          "exit 0"
        ])
      )

    {_task, run} = assign(ctx, agent)
    await_file(machine.port, barrier <> ".ready", "CLI reached late-push barrier")

    now = DateTime.utc_now(:second)
    Application.put_env(:helmsman, :daemon_clock, fn -> now end)
    on_exit(fn -> Application.delete_env(:helmsman, :daemon_clock) end)

    Repo.update_all(from(d in Daemon, where: d.id == ^machine.daemon.id),
      set: [last_seen_at: DateTime.add(now, -180, :second)]
    )

    assert :ok = Sweep.perform(%{})

    assert %Run{status: :failed, failure_reason: :runtime_offline} = Repo.get!(Run, run.id)

    File.write!(barrier <> ".release", "release")

    run = wait_push(machine.port, run, "late push after Sweep")
    assert %Run{status: :failed, failure_reason: :runtime_offline, push_status: :pushed} = run

    assert Repo.get!(Run, run.id).head_sha == GitWorkspaceE2E.head(ctx.remote, run.branch)
  end

  test "3.3 a later run pushes the three-attempt rejected commit from its ledger", ctx do
    wrapper = GitWorkspaceE2E.receive_pack_wrapper(ctx.home)
    GitWorkspaceE2E.reject_first_pushes(ctx.remote, 3)

    machine =
      start_machine(ctx, 1, %{
        heartbeat_interval_ms: 60_000,
        run_worker_opts: %{
          allow_file_urls: true,
          push_backoff_ms: [0, 0],
          push_args: ["--receive-pack=#{wrapper}"]
        }
      })

    agent =
      make_agent(
        ctx,
        machine.runtime,
        scenario(ctx.home, "rejected", ["write inherited", result("first"), "exit 0"])
      )

    {task, first_run} = assign(ctx, agent)

    assert %Run{status: :failed, failure_reason: :push_failed, push_status: :failed} =
             wait_status(machine.port, first_run, [:succeeded, :failed], "first rejected push")

    assert File.read!(Path.join(Path.dirname(ctx.remote.bare), "pre-receive-count")) == "3"
    branch = task_branch(ctx, task)

    first_head =
      GitWorkspaceE2E.git!(worktree(machine.home, ctx.workspace.id, task.ident), [
        "rev-parse",
        "HEAD"
      ])
      |> String.trim()

    refute GitWorkspaceE2E.branch?(ctx.remote, branch)

    File.rm!(Path.join([ctx.remote.bare, "hooks", "pre-receive"]))

    update_agent(
      agent,
      machine.runtime,
      scenario(ctx.home, "inherited", [result("second"), "exit 0"])
    )

    second_run = manual_retry(ctx, Repo.get!(Run, first_run.id))

    second_run =
      assert %Run{status: :succeeded, push_status: :pushed, head_sha: ^first_head} =
               wait_status(machine.port, second_run, [:succeeded, :failed], "inherited push")

    first_run = Repo.get!(Run, first_run.id)
    assert first_run.push_status == :pushed
    assert first_run.head_sha == first_head
    assert Enum.any?(first_run.push_commits, &(&1["sha"] == first_head))
    assert Enum.any?(second_run.push_commits, &(&1["sha"] == first_head))
    assert GitWorkspaceE2E.head(ctx.remote, first_run.branch) == first_head
  end

  test "3.4 killing the RunWorker while the pushed response is synchronously held is reconciled",
       ctx do
    machine =
      start_machine(ctx, 1, %{
        heartbeat_interval_ms: 100,
        run_worker_opts: %{allow_file_urls: true}
      })

    cli_barrier = Path.join(ctx.home, "before-push")

    agent =
      make_agent(
        ctx,
        machine.runtime,
        scenario(ctx.home, "uncertain", [
          "write committed",
          "barrier #{cli_barrier}",
          result("first"),
          "exit 0"
        ])
      )

    {task, first_run} = assign(ctx, agent)
    await_file(machine.port, cli_barrier <> ".ready", "CLI ready before pushed telemetry handler")
    _handler = GitWorkspaceE2E.attach_after_push(self(), first_run.id)
    File.write!(cli_barrier <> ".release", "release")

    assert_receive {:git_workspace_after_push, run_id, channel_pid}, 10_000
    assert run_id == first_run.id

    first_run = Repo.get!(Run, first_run.id)
    remote_head = GitWorkspaceE2E.head(ctx.remote, first_run.branch)
    assert first_run.push_status == :pushed
    assert first_run.head_sha == remote_head
    commit_count = GitWorkspaceE2E.commit_count(ctx.remote, first_run.branch)

    assert %{"run_id" => run_id, "status" => "killed"} =
             GitWorkspaceE2E.kill_run(machine.port, machine.home, "hold-pushed", run_id)

    ledger_path = ledger_path(machine.home, ctx.workspace.id, task.ident)
    ledger = ledger_path |> File.read!() |> Jason.decode!()

    assert [%{"head_sha" => ^remote_head, "runs" => [%{"run_id" => ^run_id, "acked" => false}]}] =
             ledger["outbox"]

    GitWorkspaceE2E.release_after_push(channel_pid, run_id)

    first_run =
      wait_until_run(machine.port, first_run, &(&1.status == :failed), "killed worker reconciled")

    assert first_run.push_status == :pushed
    assert first_run.failure_reason == :unknown

    update_agent(
      agent,
      machine.runtime,
      scenario(ctx.home, "ledger-retry", [result("second"), "exit 0"])
    )

    second_run = manual_retry(ctx, Repo.get!(Run, first_run.id))

    assert %Run{status: :succeeded, push_status: :none} =
             wait_status(
               machine.port,
               second_run,
               [:succeeded, :failed],
               "ledger acknowledgement recovery"
             )

    assert GitWorkspaceE2E.head(ctx.remote, first_run.branch) == remote_head
    assert GitWorkspaceE2E.commit_count(ctx.remote, first_run.branch) == commit_count
    reloaded_first_run = Repo.get!(Run, first_run.id)
    assert reloaded_first_run.push_status == :pushed
    assert reloaded_first_run.failure_reason == :unknown
    refute File.exists?(ledger_path)
  end

  defp start_machine(ctx, index, options) do
    {daemon, token} = daemon_fixture(ctx.owner, %{workspace_ids: [ctx.workspace.id]})
    home = Path.join(ctx.home, "machine-#{index}")
    File.mkdir_p!(home)
    DaemonE2E.write_credentials(home, ctx.endpoint_url, daemon.id, token)

    port =
      DaemonE2E.start_e2e_daemon(
        home,
        Map.put_new(options, :run_worker_opts, %{allow_file_urls: true})
      )

    runtime =
      DaemonE2E.wait_until(port, "runtime #{daemon.id} online", fn ->
        case Repo.get_by(Runtime, daemon_id: daemon.id, workspace_id: ctx.workspace.id) do
          %Runtime{status: "online"} = online -> online
          _ -> nil
        end
      end)

    %{daemon: daemon, home: home, port: port, runtime: runtime}
  end

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

  defp assign(ctx, agent) do
    task = task_fixture(ctx.scope, ctx.project.key, %{assignee: agent.name})
    [run] = runs_of(task.id)
    {task, run}
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

  defp manual_retry(ctx, %Run{} = run) do
    case Runs.retry(ctx.scope, run.id) do
      {:ok, %{id: id}} -> id
      {:error, {:already_retried, id}} -> id
      other -> flunk("could not retry run #{run.id}: #{inspect(other)}")
    end
  end

  defp scenario(home, name, lines) do
    path = Path.join(home, "#{name}.scenario")
    File.write!(path, Enum.join(lines, "\n") <> "\n")
    path
  end

  defp wait_status(port, run, statuses, label) do
    id = if match?(%Run{}, run), do: run.id, else: run

    DaemonE2E.wait_until(
      port,
      fn -> "#{label} (#{inspect(Repo.get!(Run, id), limit: :infinity)})" end,
      fn ->
        run = Repo.get!(Run, id)
        if run.status in statuses, do: run
      end
    )
  end

  defp wait_until_run(port, %Run{id: id}, predicate, label) do
    DaemonE2E.wait_until(port, label, fn ->
      run = Repo.get!(Run, id)
      if predicate.(run), do: run
    end)
  end

  defp wait_push(port, %Run{id: id}, label) do
    DaemonE2E.wait_until(port, label, fn ->
      run = Repo.get!(Run, id)
      if run.push_status == :pushed, do: run
    end)
  end

  defp await_file(port, path, label) do
    DaemonE2E.wait_until(port, label, fn -> if File.exists?(path), do: path end)
  end

  defp result(text), do: ~s(json {"type":"result","data":{"text":"#{text}","success":true}})

  defp worktree(home, workspace_id, ident),
    do: Path.join([home, "work", Integer.to_string(workspace_id), ident])

  defp task_branch(ctx, task), do: "hm/#{ctx.workspace.id}/#{String.downcase(task.ident)}"

  defp ledger_path(home, workspace_id, ident),
    do: Path.join([home, "state", "worktrees", Integer.to_string(workspace_id), "#{ident}.json"])

  defp assert_git_ancestor(directory, sha),
    do: GitWorkspaceE2E.git!(directory, ["merge-base", "--is-ancestor", sha, "HEAD"])
end
