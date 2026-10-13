defmodule Helmsman.E2E.SquadTest do
  # add-squads 6.1: a squad works a task end to end with the daemon of
  # `daemon/` and its fake CLI. The fake CLI cannot call MCP itself: at a
  # `barrier` the test acts as the CLI, with a fresh token of the run, and
  # calls the MCP tools through the endpoint. Run with
  # `mix test --only e2e test/e2e/squad_test.exs`.
  use ExUnit.Case, async: false

  @moduletag :e2e
  if :os.type() != {:unix, :linux} do
    @moduletag skip: "daemon E2E tests require Linux"
  end

  @moduletag timeout: 240_000

  import Ecto.Query
  import Helmsman.AccountsFixtures
  import Helmsman.AgentsFixtures
  import Helmsman.ProjectsFixtures
  import Helmsman.RunsFixtures
  import Helmsman.SquadsFixtures
  import Helmsman.WorkspacesFixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias Helmsman.{CommittedData, DaemonE2E, Repo, Tasks}
  alias Helmsman.Daemons.Runtime
  alias Helmsman.Runs.{Run, RunToken, RunTokens, Spec}
  alias Helmsman.Tasks.Task
  alias HelmsmanWeb.MCPClient

  setup do
    :ok = Sandbox.mode(Repo, :auto)
    on_exit(fn -> Sandbox.mode(Repo, :manual) end)

    tag = Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
    home = Path.join(System.tmp_dir!(), "helmsman-e2e-squad-#{tag}")
    File.mkdir_p!(home)
    unless System.get_env("HELMSMAN_E2E_KEEP"), do: on_exit(fn -> File.rm_rf!(home) end)

    {alice, workspace, scope, project, daemon, token} =
      CommittedData.unboxed(fn ->
        alice = user_fixture(%{email: "squad-e2e-#{tag}@test.invalid"})
        workspace = workspace_fixture(alice, %{slug: "squad-e2e-#{tag}", name: "Squad #{tag}"})
        scope = workspace_scope_fixture(alice, workspace)
        project = project_fixture(scope)
        {daemon, token} = daemon_fixture(alice, %{workspace_ids: [workspace.id]})
        {alice, workspace, scope, project, daemon, token}
      end)

    on_exit(fn -> CommittedData.delete_user_data!([alice.id]) end)

    %{
      tag: tag,
      home: home,
      alice: alice,
      workspace: workspace,
      scope: scope,
      project: project,
      daemon: daemon,
      token: token
    }
  end

  defp start(ctx) do
    url = DaemonE2E.start_endpoint()
    DaemonE2E.write_credentials(ctx.home, url, ctx.daemon.id, ctx.token)
    port = DaemonE2E.start_daemon(ctx.home)

    runtime =
      DaemonE2E.wait_until(port, "the runtime online", fn ->
        case Repo.get_by(Runtime, daemon_id: ctx.daemon.id, workspace_id: ctx.workspace.id) do
          %Runtime{status: "online"} = runtime -> runtime
          _ -> nil
        end
      end)

    {port, runtime}
  end

  defp scenario(ctx, name, lines) do
    path = Path.join(ctx.home, name)
    File.write!(path, Enum.join(lines, "\n") <> "\n")
    path
  end

  defp result(text), do: ~s(json {"type":"result","data":{"text":"#{text}","success":true}})

  defp wait_run(port, label, fun) do
    DaemonE2E.wait_until(port, label, fn -> Repo.one(fun.()) end)
  end

  defp ended(port, run) do
    DaemonE2E.wait_until(port, "run #{run.id} ended", fn ->
      run = Repo.get!(Run, run.id)
      run.status in Run.ended_statuses() && run
    end)
  end

  # The test is the CLI of `run` at its barrier: a fresh token of the run
  # (the one the daemon got is replaced) and an MCP session with it.
  defp as_cli(port, run, barrier) do
    DaemonE2E.wait_until(port, "#{barrier} reached", fn -> File.exists?(barrier <> ".ready") end)

    token =
      CommittedData.unboxed(fn ->
        Repo.delete_all(from(t in RunToken, where: t.run_id == ^run.id))
        {:ok, token} = RunTokens.issue(Repo.get!(Run, run.id))
        token
      end)

    {token, MCPClient.handshake(token)}
  end

  defp release(barrier) do
    File.write!(barrier <> ".release", "")
  end

  defp reset(barrier) do
    File.rm(barrier <> ".ready")
    File.rm(barrier <> ".release")
  end

  test "assign a squad → delegate → member works → woken leader finishes → verified outside",
       ctx do
    {port, runtime} = start(ctx)
    lead_barrier = Path.join(ctx.home, "lead")

    lead_path =
      scenario(ctx, "lead", ["barrier #{lead_barrier}", result("Leader turn ended."), "exit 0"])

    fe_path =
      scenario(ctx, "fe", ["write hello from keel/fe", result("Wrote hello.txt."), "exit 0"])

    review_path = scenario(ctx, "review", [result("Reviewed."), "exit 0"])

    for {name, path} <- [
          {"keel/lead", lead_path},
          {"keel/fe", fe_path},
          {"keel/review", review_path}
        ] do
      managed_agent_fixture(ctx.scope, %{
        name: name,
        runtime_id: runtime.id,
        access: "workspace",
        custom_args: [path]
      })
    end

    squad_fixture(ctx.scope, %{
      name: "web-team",
      leader: "keel/lead",
      members: [
        %{name: "keel/fe", role_note: "Writes"},
        %{name: "keel/review", role_note: "Reviews"}
      ]
    })

    task = task_fixture(ctx.scope, ctx.project.key, %{title: "Say hello"})
    {:ok, _} = Tasks.update(ctx.scope, task.ident, %{assignee: "web-team"})
    lead = agent_actor(ctx.workspace, "keel/lead")
    fe = agent_actor(ctx.workspace, "keel/fe")

    # 1. The leader's run delegates to keel/fe and ends.
    [lead_run] = runs_of(task.id)
    assert lead_run.squad_id

    {token, sid} = as_cli(port, lead_run, lead_barrier)

    assert {:ok, %{"run" => %{"agent" => "keel/fe"}}} =
             MCPClient.call_tool(token, sid, "delegate", %{
               task_id: task.ident,
               to: "keel/fe",
               instructions: "Write hello.txt"
             })

    release(lead_barrier)
    assert %Run{status: :succeeded} = ended(port, lead_run)
    reset(lead_barrier)
    Oban.drain_queue(queue: :runs)
    assert Repo.get!(Task, task.id).status == :in_progress

    # 2. keel/fe's delegated run writes the file and ends.
    fe_run =
      wait_run(port, "the member's run", fn ->
        from(r in Run, where: r.task_id == ^task.id and r.agent_id == ^fe.id)
      end)

    assert %Run{status: :succeeded, summary: "Wrote hello.txt."} = ended(port, fe_run)

    # 3. delegate_done wakes the leader with keel/fe's output.
    Oban.drain_queue(queue: :runs)

    woke =
      wait_run(port, "the leader woken", fn ->
        from(r in Run,
          where: r.task_id == ^task.id and r.agent_id == ^lead.id and r.id != ^lead_run.id
        )
      end)

    assert [%{"kind" => "delegate_done", "member" => "keel/fe"}] = woke.triggers

    {token, sid} = as_cli(port, woke, lead_barrier)

    {:ok, spec} =
      Spec.build(Repo.get!(Run, woke.id), "hmr_" <> String.duplicate("a", 52), "http://x")

    assert spec.prompt =~ "The run of keel/fe (run #{fe_run.id}) that you delegated"
    assert spec.prompt =~ "> Wrote hello.txt."

    # 4. The leader moves the task to done, without tests.
    assert {:ok, %{"status" => "DONE"}} =
             MCPClient.call_tool(token, sid, "transition_task", %{task_id: task.ident, to: "done"})

    release(lead_barrier)
    assert %Run{status: :succeeded} = ended(port, woke)
    Oban.drain_queue(queue: :runs)

    # 5. A member verifying without tests is refused.
    review = agent_actor(ctx.workspace, "keel/review")

    review_run =
      CommittedData.unboxed(fn ->
        run_fixture(review, %{
          task_id: task.id,
          status: :succeeded,
          capabilities: ["read", "write_task"]
        })
      end)

    review_token =
      CommittedData.unboxed(fn ->
        {:ok, token} = RunTokens.issue(review_run)

        Repo.update_all(from(r in Run, where: r.id == ^review_run.id), set: [status: :running])
        token
      end)

    review_sid = MCPClient.handshake(review_token)

    assert {:error, text} =
             MCPClient.call_tool(review_token, review_sid, "transition_task", %{
               task_id: task.ident,
               to: "verified"
             })

    assert text =~ "You are on the assignee side of #{task.ident} (squad web-team)"

    CommittedData.unboxed(fn ->
      Repo.update_all(from(r in Run, where: r.id == ^review_run.id), set: [status: :succeeded])
    end)

    # 6. alice, outside the squad, verifies.
    assert {:ok, _} = Tasks.transition(ctx.scope, task.ident, :verified)
    assert Repo.get!(Task, task.id).status == :verified
  end
end
