defmodule HelmsmanWeb.DaemonChannelRunsTest do
  # add-run-lifecycle 6.1: the run messages of the daemon channel and its
  # pushes (decisions 2, 18). Payloads are encoded and replies decoded
  # with `HelmsmanProtocol.Messages`, as the daemon does.
  use ExUnit.Case, async: false

  import Phoenix.ChannelTest
  import Ecto.Query, only: [from: 2]
  import Helmsman.AccountsFixtures
  import Helmsman.AgentsFixtures
  import Helmsman.ProjectsFixtures
  import Helmsman.RunsFixtures
  import Helmsman.WorkspacesFixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias Helmsman.Daemons.Daemon
  alias Helmsman.{Events, Repo, Runs}
  alias Helmsman.Runs.{Run, RunEvent}
  alias HelmsmanProtocol.{ErrorReply, Event, Messages, Push, Reply, Report}
  alias HelmsmanWeb.{DaemonChannel, DaemonSocket}

  @endpoint HelmsmanWeb.Endpoint

  setup do
    pid = Sandbox.start_owner!(Repo, shared: true)
    on_exit(fn -> Sandbox.stop_owner(pid) end)

    alice = user_fixture()
    workspace = workspace_fixture(alice)
    scope = workspace_scope_fixture(alice, workspace)
    {daemon, token} = daemon_fixture(alice, %{workspace_ids: [workspace.id]})
    runtime = runtime_fixture(workspace, daemon)
    managed_agent_fixture(scope, %{name: "keel/dev", runtime_id: runtime.id})
    project = project_fixture(scope)
    task = task_fixture(scope, project.key, %{assignee: "keel/dev"})
    [run] = runs_of(task.id)

    %{
      alice: alice,
      workspace: workspace,
      scope: scope,
      daemon: daemon,
      token: token,
      task: task,
      run: run
    }
  end

  defp encode!(struct) do
    {:ok, {_name, payload}} = Messages.encode(struct)
    payload
  end

  defp new!(module, attrs) do
    {:ok, value} = module.new(attrs)
    value
  end

  defp join_payload(daemon, active_runs) do
    Report.Join
    |> new!(%{
      protocol: HelmsmanProtocol.version(),
      machine: %{
        machine_id: daemon.machine_id,
        name: "alice-laptop",
        os: "linux",
        arch: "x86_64",
        daemon_version: "0.2.0"
      },
      clis: [
        %{
          provider: :claude,
          version: "2.0.0",
          models: [],
          efforts: [],
          available: true,
          unavailable_reason: nil
        }
      ],
      max_concurrency: 4,
      active_runs: Enum.map(active_runs, &%{run_id: &1, last_seq: 0})
    })
    |> encode!()
  end

  defp joined(ctx, active_runs \\ []) do
    {:ok, socket} =
      connect(DaemonSocket, %{},
        connect_info: %{x_headers: [{HelmsmanProtocol.token_header(), ctx.token}]}
      )

    assert {:ok, reply, socket} =
             join(
               socket,
               DaemonChannel,
               "daemon:#{ctx.daemon.id}",
               join_payload(ctx.daemon, active_runs)
             )

    assert {:ok, %Reply.Join{} = reply} = Messages.decode_reply("join", reply)
    {socket, reply}
  end

  defp request(socket, name, struct) do
    ref = push(socket, name, encode!(struct))
    assert_reply ref, status, payload, 5_000

    case status do
      :ok ->
        assert {:ok, reply} = Messages.decode_reply(name, payload)
        {:ok, reply}

      :error ->
        assert {:ok, %ErrorReply{reason: reason}} = ErrorReply.from_wire(payload)
        {:error, reason}
    end
  end

  defp reload(run), do: Repo.get!(Run, run.id)

  test "claim → starting → started → events → finished", ctx do
    {socket, _reply} = joined(ctx)
    id = ctx.run.id

    assert {:ok, %Reply.Claim{runs: [spec]}} = request(socket, "claim", %Report.Claim{})
    assert spec.run_id == id
    assert spec.mcp.url == HelmsmanWeb.Endpoint.url() <> "/mcp"
    assert spec.prompt =~ "assigned #{ctx.task.ident} to you."
    assert reload(ctx.run).status == :claimed

    assert {:ok, %Reply.Starting{action: :proceed}} =
             request(socket, "starting", %Report.Starting{run_id: id})

    assert {:ok, %Reply.Empty{}} =
             request(socket, "started", %Report.Started{run_id: id, session_id: "s-1"})

    events =
      for seq <- 1..2,
          do: new!(Event, %{seq: seq, type: :text, data: %{text: "hi"}, at: DateTime.utc_now()})

    assert {:ok, %Reply.Events{acked_seq: 2}} =
             request(socket, "events", new!(Report.Events, %{run_id: id, events: events}))

    finished = new!(Report.Finished, %{run_id: id, status: :succeeded, summary: "Done."})
    assert {:ok, %Reply.Empty{}} = request(socket, "finished", finished)

    assert %Run{status: :succeeded, session_id: "s-1", summary: "Done."} = reload(ctx.run)
    assert Repo.aggregate(from(e in RunEvent, where: e.run_id == ^id), :count) == 2

    # Reported again after the end: the same end is fine, events are not.
    assert {:ok, %Reply.Empty{}} = request(socket, "finished", finished)

    assert {:error, :wrong_state} =
             request(socket, "events", new!(Report.Events, %{run_id: id, events: events}))
  end

  test "a gap in the events is invalid_payload", ctx do
    {socket, _reply} = joined(ctx)
    {:ok, %Reply.Claim{runs: [_]}} = request(socket, "claim", %Report.Claim{})
    {:ok, _} = request(socket, "starting", %Report.Starting{run_id: ctx.run.id})
    event = new!(Event, %{seq: 3, type: :text, data: %{text: "hi"}, at: DateTime.utc_now()})

    assert {:error, :invalid_payload} =
             request(
               socket,
               "events",
               new!(Report.Events, %{run_id: ctx.run.id, events: [event]})
             )
  end

  test "join: reported runs to terminate; cancelling ones get cancel again", ctx do
    {other, _token} = daemon_fixture(ctx.alice, %{workspace_ids: [ctx.workspace.id]})
    agent = agent_actor(ctx.workspace, "keel/dev")
    theirs = run_fixture(agent, %{status: :running, daemon_id: other.id})

    cancelling =
      run_fixture(agent, %{
        status: :cancelling,
        daemon_id: ctx.daemon.id,
        claimed_at: DateTime.utc_now()
      })

    lost =
      run_fixture(agent, %{
        status: :running,
        daemon_id: ctx.daemon.id,
        claimed_at: DateTime.utc_now()
      })

    {_socket, reply} = joined(ctx, [theirs.id, cancelling.id])
    assert reply.terminate_run_ids == [theirs.id]
    assert_push "cancel", payload
    assert {:ok, %Push.Cancel{run_id: cancel_id}} = Messages.decode("cancel", payload)
    assert cancel_id == cancelling.id

    # Not reported on join: no grace.
    assert %Run{status: :failed, failure_reason: :daemon_restart} = reload(lost)
  end

  test "heartbeat replies the runs to terminate", ctx do
    {socket, _reply} = joined(ctx)

    assert {:ok, %Reply.Heartbeat{terminate_run_ids: [id]}} =
             request(
               socket,
               "heartbeat",
               new!(Report.Heartbeat, %{runs: [%{run_id: ctx.run.id, last_seq: 0}]})
             )

    assert id == ctx.run.id
  end

  test "runs_available and cancel are pushed", ctx do
    {socket, _reply} = joined(ctx)

    Helmsman.Tx.run(fn ->
      Events.after_commit(Events.topic(:daemon, ctx.daemon.id), {:runs_available})
      {:ok, :ok}
    end)

    assert_push "runs_available", _payload

    {:ok, %Reply.Claim{runs: [_]}} = request(socket, "claim", %Report.Claim{})
    assert {:ok, %{status: "cancelling"}} = Runs.cancel(ctx.scope, ctx.run.id)
    assert_push "cancel", payload
    assert {:ok, %Push.Cancel{run_id: id}} = Messages.decode("cancel", payload)
    assert id == ctx.run.id
  end

  test "git_token, pushed and steer_ack are not_found", ctx do
    {socket, _reply} = joined(ctx)
    id = ctx.run.id

    assert {:error, :not_found} = request(socket, "git_token", %Report.GitToken{run_id: id})

    assert {:error, :not_found} =
             request(socket, "steer_ack", %Report.SteerAck{run_id: id, feedback_id: 1})

    pushed =
      new!(Report.Pushed, %{
        run_id: id,
        branch: "b",
        base_sha: "a",
        head_sha: "c",
        commits: [],
        rescue_branch: nil
      })

    assert {:error, :not_found} = request(socket, "pushed", pushed)
    assert Process.alive?(socket.channel_pid)
  end

  test "another daemon's run is not_found; an old epoch is not_found and disconnects", ctx do
    {other, other_token} = daemon_fixture(ctx.alice, %{workspace_ids: [ctx.workspace.id]})
    {socket, _reply} = joined(ctx)
    {:ok, %Reply.Claim{runs: [_]}} = request(socket, "claim", %Report.Claim{})

    {other_socket, _} = joined(%{ctx | daemon: other, token: other_token})

    assert {:error, :not_found} =
             request(other_socket, "starting", %Report.Starting{run_id: ctx.run.id})

    Repo.update_all(from(d in Daemon, where: d.id == ^ctx.daemon.id), inc: [auth_epoch: 1])
    monitor = Process.monitor(socket.channel_pid)

    assert {:error, :not_found} =
             request(socket, "starting", %Report.Starting{run_id: ctx.run.id})

    pid = socket.channel_pid
    assert_receive {:DOWN, ^monitor, :process, ^pid, _reason}
    assert reload(ctx.run).status == :claimed
  end
end
