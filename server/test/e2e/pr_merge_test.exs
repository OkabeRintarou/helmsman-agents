defmodule Helmsman.E2E.PrMergeTest do
  # add-pr-reconcile-merge 3.1: the server, the real daemon (protocol Vc),
  # the fake CLI, a local bare remote and a fake GitHub API (`Req.Test`,
  # recorded bodies) whose pull requests and branches follow the bare
  # repository. Reconciliations run with `perform_job/2` (Oban testing is
  # `:manual`). Run with `mix test --only e2e`.
  use ExUnit.Case, async: false
  use Oban.Testing, repo: Helmsman.Repo

  @moduletag :e2e
  if :os.type() != {:unix, :linux} do
    @moduletag skip: "daemon E2E tests require Linux"
  end

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
  alias Helmsman.Daemons.Runtime
  alias Helmsman.FakeGitHub
  alias Helmsman.Feedback.Entry
  alias Helmsman.GitHub.PullRequest
  alias Helmsman.GitHub.Workers.ReconcilePR
  alias Helmsman.GitWorkspaceE2E
  alias Helmsman.Repo
  alias Helmsman.Runs
  alias Helmsman.Runs.{Origin, Run, RunEvent, RunToken}
  alias Helmsman.Runs.Workers.SideEffect
  alias Helmsman.Tasks
  alias Helmsman.Tasks.Task
  alias Helmsman.Tx

  setup do
    :ok = Sandbox.mode(Repo, :auto)
    on_exit(fn -> Sandbox.mode(Repo, :manual) end)

    tag = Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
    home = Path.join(System.tmp_dir!(), "helmsman-e2e-pr-#{tag}")
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

    {owner, workspace, scope, project} =
      CommittedData.unboxed(fn ->
        owner = user_fixture(%{email: "pr-e2e-#{tag}@test.invalid"})
        workspace = workspace_fixture(owner, %{slug: "pr-e2e-#{tag}", name: "PR e2e #{tag}"})
        scope = workspace_scope_fixture(owner, workspace)
        project = project_fixture(scope)
        installation = installation_fixture(workspace)

        repository =
          repository_fixture(installation, %{owner: "acme", name: "app", default_branch: "main"})

        :ok = bind_repository(project, repository)
        {owner, workspace, scope, project}
      end)

    on_exit(fn ->
      task_ids =
        Repo.all(from(t in Task, where: t.workspace_id == ^workspace.id, select: t.id))
        |> Enum.map(&to_string/1)

      Repo.delete_all(from(j in Oban.Job, where: fragment("?->>'task_id'", j.args) in ^task_ids))

      CommittedData.delete_user_data!([owner.id])
    end)

    :ok = Req.Test.set_req_test_to_shared(self())
    on_exit(fn -> Req.Test.set_req_test_to_private() end)
    fake = FakeGitHub.start("acme", "app", %{bare: remote.bare})
    endpoint_url = DaemonE2E.start_endpoint()

    %{
      home: home,
      remote: remote,
      owner: owner,
      workspace: workspace,
      scope: scope,
      project: project,
      fake: fake,
      endpoint_url: endpoint_url
    }
  end

  test "pushed, drafted, made ready, verified, checked, merged by sha, branch and worktree removed",
       ctx do
    machine = start_machine(ctx)
    agent = make_agent(ctx, machine.runtime, scenario(ctx, "first", ["write first", ok()]))

    {task, first_run} = assign(ctx, agent)
    branch = "hm/#{ctx.workspace.id}/#{String.downcase(task.ident)}"

    assert %Run{status: :succeeded, push_status: :pushed} =
             wait_run(machine.port, first_run.id, "first push")

    head = GitWorkspaceE2E.head(ctx.remote, branch)
    run_side_effects(task)
    assert status(task) == :in_progress

    # The first push opens a draft.
    assert :ok = reconcile(task)

    assert [%{"head" => ^branch, "base" => "main", "draft" => true}] =
             request_bodies(ctx.fake, "POST", "/repos/acme/app/pulls")

    assert %PullRequest{number: 1, state: :draft, head_sha: ^head} = current_pr(task)
    assert FakeGitHub.pull(ctx.fake, 1).draft

    # The agent sets DONE inside its next run; the pull request becomes ready.
    barrier = Path.join(ctx.home, "done")
    update_agent(agent, scenario(ctx, "done", ["barrier #{barrier}", ok()]))
    done_run = enqueue(ctx, task, agent)
    await_file(machine.port, barrier <> ".ready", "agent run reached its barrier")
    run_scope = agent_scope(done_run)
    assert {:ok, _} = Tasks.transition(run_scope, task.ident, :done)
    File.write!(barrier <> ".release", "release")

    assert %Run{status: :succeeded, push_status: :none} =
             wait_run(machine.port, done_run, "done run")

    assert :ok = reconcile(task)
    refute FakeGitHub.pull(ctx.fake, 1).draft
    assert %PullRequest{state: :open} = current_pr(task)

    # alice verifies; CI has not reported yet, so the merge waits.
    assert {:ok, _} = Tasks.transition(ctx.scope, task.ident, :verified)
    assert :ok = reconcile(task)
    assert %PullRequest{merge_status: :waiting} = current_pr(task)
    refute FakeGitHub.requested?(ctx.fake, "PUT", "/pulls/1/merge")

    # Checks pass: merged with the verified commit, then the branch goes.
    FakeGitHub.update(
      ctx.fake,
      &%{&1 | checks: Map.put(&1.checks, head, [FakeGitHub.check_run("test", "success")])}
    )

    reconcile_until(task, "merged and branch deleted", fn ->
      match?(%PullRequest{state: :merged}, current_pr(task)) and
        not GitWorkspaceE2E.branch?(ctx.remote, branch)
    end)

    assert [%{"sha" => ^head, "merge_method" => "squash"}] =
             request_bodies(ctx.fake, "PUT", "/repos/acme/app/pulls/1/merge")

    assert %PullRequest{state: :merged, merge_status: :merged} = current_pr(task)
    assert GitWorkspaceE2E.show(ctx.remote, "main", "hello.txt") == "first\n"
    assert status(task) == :verified

    # The next cleanup round (the first after the daemon joins again)
    # deletes the daemon's worktree of the task.
    worktree = Path.join([machine.home, "work", to_string(ctx.workspace.id), task.ident])
    assert File.dir?(worktree)
    DaemonE2E.stop_daemon(machine.port)
    port = start_daemon(machine.home)

    DaemonE2E.wait_until(port, "cleanup removed #{worktree}", fn ->
      not File.exists?(worktree)
    end)
  end

  test "failing checks reopen the task and the executor's fix run sees the CI failure", ctx do
    machine = start_machine(ctx)
    barrier = Path.join(ctx.home, "done")

    agent =
      make_agent(
        ctx,
        machine.runtime,
        scenario(ctx, "first", ["write first", "barrier #{barrier}", ok()])
      )

    {task, first_run} = assign(ctx, agent)
    await_file(machine.port, barrier <> ".ready", "agent run reached its barrier")
    run_side_effects(task)
    run_scope = agent_scope(first_run.id)
    assert {:ok, _} = Tasks.transition(run_scope, task.ident, :done)
    File.write!(barrier <> ".release", "release")

    assert %Run{status: :succeeded, push_status: :pushed, head_sha: head} =
             wait_run(machine.port, first_run.id, "first push")

    assert :ok = reconcile(task)
    assert %PullRequest{number: 1, state: :open, head_sha: ^head} = current_pr(task)
    assert {:ok, _} = Tasks.transition(ctx.scope, task.ident, :verified)

    failed =
      FakeGitHub.check_run("test", "failure", %{
        "details_url" => "https://github.com/acme/app/actions/runs/7",
        "output" => %{"title" => "1 test failed", "summary" => "expected 2, got 3"}
      })

    FakeGitHub.update(ctx.fake, &%{&1 | checks: Map.put(&1.checks, head, [failed])})

    # The fix run prints its prompt.
    update_agent(agent, scenario(ctx, "fix", ["echo_stdin", ok()]))
    assert :ok = reconcile(task)

    assert status(task) == :in_progress
    assert %PullRequest{auto_reopen_count: 1} = current_pr(task)
    refute FakeGitHub.requested?(ctx.fake, "PUT", "/pulls/1/merge")

    assert [%Entry{kind: :review, content: review}] =
             Repo.all(from(e in Entry, where: e.task_id == ^task.id and e.kind == :review))

    ci_line = "- test: failure https://github.com/acme/app/actions/runs/7"
    assert review =~ ci_line

    fix_run =
      DaemonE2E.wait_until(machine.port, "fix run claimed", fn ->
        Enum.find(runs_of(task.id), &(&1.id > first_run.id and &1.claimed_at))
      end)

    assert %Run{status: :succeeded} = wait_run(machine.port, fix_run.id, "fix run")
    assert fix_run.agent_id == agent.id

    prompt =
      Repo.all(
        from(e in RunEvent,
          where: e.run_id == ^fix_run.id and e.type == "text",
          order_by: e.seq,
          select: e.data["text"]
        )
      )

    assert Enum.any?(prompt, &String.contains?(&1, ci_line)),
           "the fix run's prompt has no CI failure line:\n#{Enum.join(prompt, "\n")}"
  end

  defp reconcile(%Task{id: id}), do: perform_job(ReconcilePR, %{task_id: id})

  # The run side effects (auto-claim, fallback comment) that Oban would run.
  defp run_side_effects(%Task{id: id}) do
    run_ids = Enum.map(runs_of(id), &to_string(&1.id))
    worker = Oban.Worker.to_string(SideEffect)

    jobs =
      Repo.all(
        from(j in Oban.Job,
          where: j.worker == ^worker and j.state == "available",
          where: fragment("?->>'run_id'", j.args) in ^run_ids,
          order_by: j.id
        )
      )

    for job <- jobs do
      assert :ok = perform_job(SideEffect, job.args)
      Repo.update_all(from(j in Oban.Job, where: j.id == ^job.id), set: [state: "completed"])
    end
  end

  # The scope of the agent's MCP calls in run `run_id`. The daemon holds
  # the run's only token; replace it with one issued here (the fake CLI
  # does not call the server).
  defp agent_scope(run_id) do
    Repo.delete_all(from(t in RunToken, where: t.run_id == ^run_id))
    {scope, _token} = run_scope_fixture(Repo.get!(Run, run_id))
    scope
  end

  # Reconciles (as Oban's follow-up polls would) until `fun` holds.
  defp reconcile_until(task, label, fun, attempts \\ 5) do
    cond do
      fun.() ->
        :ok

      attempts == 0 ->
        flunk("not #{label}: #{inspect(current_pr(task))}")

      true ->
        assert :ok = reconcile(task)
        reconcile_until(task, label, fun, attempts - 1)
    end
  end

  defp current_pr(%Task{id: id}),
    do:
      Repo.one(from(p in PullRequest, where: p.task_id == ^id, order_by: [desc: p.id], limit: 1))

  defp status(%Task{id: id}), do: Repo.get!(Task, id).status

  defp request_bodies(fake, method, path),
    do:
      for(
        %{method: ^method, path: ^path, body: b} <- FakeGitHub.requests_with_bodies(fake),
        do: b
      )

  defp start_machine(ctx) do
    {daemon, token} =
      CommittedData.unboxed(fn ->
        daemon_fixture(ctx.owner, %{workspace_ids: [ctx.workspace.id]})
      end)

    home = Path.join(ctx.home, "machine")
    DaemonE2E.write_credentials(home, ctx.endpoint_url, daemon.id, token)
    port = start_daemon(home)

    runtime =
      DaemonE2E.wait_until(port, "runtime #{daemon.id} online", fn ->
        case Repo.get_by(Runtime, daemon_id: daemon.id, workspace_id: ctx.workspace.id) do
          %Runtime{status: "online"} = online -> online
          _ -> nil
        end
      end)

    %{home: home, port: port, runtime: runtime}
  end

  defp start_daemon(home),
    do:
      DaemonE2E.start_e2e_daemon(home, %{
        heartbeat_interval_ms: 60_000,
        run_worker_opts: %{allow_file_urls: true}
      })

  defp make_agent(ctx, runtime, scenario) do
    managed_agent_fixture(ctx.scope, %{
      name: "keel/dev",
      runtime_id: runtime.id,
      custom_args: [scenario]
    })

    agent_actor(ctx.workspace, "keel/dev")
  end

  defp update_agent(agent, scenario) do
    profile = Repo.get_by!(AgentProfile, actor_id: agent.id)
    Repo.update!(Ecto.Changeset.change(profile, custom_args: [scenario]))
  end

  defp assign(ctx, agent) do
    task = task_fixture(ctx.scope, ctx.project.key, %{assignee: agent.name})
    [run] = runs_of(task.id)
    {task, run}
  end

  defp enqueue(ctx, task, agent) do
    profile = Repo.get_by!(AgentProfile, actor_id: agent.id)

    {:ok, outcome} =
      Tx.run(fn ->
        Runs.enqueue(
          Origin.from_scope(ctx.scope),
          %{agent: agent, profile: profile, task: Repo.get!(Task, task.id)},
          %{kind: :manual, instructions: "finish the task"}
        )
      end)

    outcome.run_id
  end

  defp scenario(ctx, name, lines) do
    path = Path.join(ctx.home, "#{name}.scenario")
    File.write!(path, Enum.join(lines, "\n") <> "\n")
    path
  end

  defp ok, do: ~s(json {"type":"result","data":{"text":"ok","success":true}}) <> "\nexit 0"

  defp wait_run(port, id, label) do
    DaemonE2E.wait_until(
      port,
      fn -> "#{label} (#{inspect(Repo.get!(Run, id))})" end,
      fn ->
        run = Repo.get!(Run, id)
        if run.status in [:succeeded, :failed, :cancelled], do: run
      end
    )
  end

  defp await_file(port, path, label),
    do: DaemonE2E.wait_until(port, label, fn -> if File.exists?(path), do: path end)
end
