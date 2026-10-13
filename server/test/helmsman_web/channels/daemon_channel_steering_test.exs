defmodule HelmsmanWeb.DaemonChannelSteeringTest do
  # add-run-steering 1.4, 1.6: the steer push, steer_ack and pushing again
  # after a join (decisions 3, 6, 8). Payloads are encoded and replies
  # decoded with `HelmsmanProtocol.Messages`, as the daemon does.
  use ExUnit.Case, async: false

  import Phoenix.ChannelTest
  import Ecto.Query, only: [from: 2]
  import Helmsman.AccountsFixtures
  import Helmsman.AgentsFixtures
  import Helmsman.ProjectsFixtures
  import Helmsman.RunsFixtures
  import Helmsman.WorkspacesFixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias Helmsman.{Feedback, Repo}
  alias Helmsman.Runs.{Run, RunSteer}
  alias HelmsmanProtocol.{ErrorReply, Messages, Push, Reply, Report}
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
    task = task_fixture(scope, project.key)
    agent = agent_actor(workspace, "keel/dev")

    %{
      alice: alice,
      workspace: workspace,
      scope: scope,
      daemon: daemon,
      token: token,
      task: task,
      agent: agent
    }
  end

  defp encode!(struct) do
    {:ok, {_name, payload}} = Messages.encode(struct)
    payload
  end

  defp join_payload(daemon, active_runs) do
    {:ok, report} =
      Report.Join.new(%{
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

    encode!(report)
  end

  defp joined(ctx, active_runs) do
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

    assert {:ok, %Reply.Join{}} = Messages.decode_reply("join", reply)
    socket
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

  defp running(ctx, status \\ :running) do
    run_fixture(ctx.agent, %{
      task_id: ctx.task.id,
      status: status,
      daemon_id: ctx.daemon.id,
      claimed_at: DateTime.utc_now(),
      started_at: DateTime.utc_now()
    })
  end

  defp record(ctx, content) do
    {:ok, entry} = Feedback.add(ctx.scope, ctx.task.ident, %{content: content})
    entry
  end

  defp pushed!(ctx, run, entry, sent_at, acked_at \\ nil) do
    Repo.insert!(%RunSteer{
      workspace_id: ctx.workspace.id,
      run_id: run.id,
      feedback_id: entry.id,
      sent_at: sent_at,
      acked_at: acked_at
    })
  end

  defp next_steer do
    assert_push "steer", payload
    assert {:ok, %Push.Steer{} = steer} = Messages.decode("steer", payload)
    steer
  end

  test "steering pushes steer; steer_ack replies empty and records the receipt", ctx do
    run = running(ctx)
    socket = joined(ctx, [run.id])

    {:ok, entry} =
      Feedback.add(ctx.scope, ctx.task.ident, %{content: "Use X", steer_run_id: run.id})

    steer = next_steer()
    assert {steer.run_id, steer.feedback_id} == {run.id, entry.id}
    assert steer.text =~ Feedback.view(entry).id
    assert steer.text =~ "> Use X"

    ack = %Report.SteerAck{run_id: run.id, feedback_id: entry.id}
    assert {:ok, %Reply.Empty{}} = request(socket, "steer_ack", ack)
    assert {:ok, %Reply.Empty{}} = request(socket, "steer_ack", ack)
    assert %RunSteer{acked_at: %DateTime{}} = Repo.get_by!(RunSteer, run_id: run.id)
  end

  test "steer_ack of an ended run is wrong_state; of another daemon's run not_found", ctx do
    run = running(ctx)
    entry = record(ctx, "x")
    pushed!(ctx, run, entry, DateTime.utc_now())
    socket = joined(ctx, [run.id])
    _ = next_steer()

    Repo.update_all(from(r in Run, where: r.id == ^run.id),
      set: [status: :failed, failure_reason: :runtime_offline]
    )

    assert {:error, :wrong_state} =
             request(socket, "steer_ack", %Report.SteerAck{run_id: run.id, feedback_id: entry.id})

    {other, _token} = daemon_fixture(ctx.alice, %{workspace_ids: [ctx.workspace.id]})

    theirs =
      run_fixture(ctx.agent, %{task_id: ctx.task.id, status: :running, daemon_id: other.id})

    assert {:error, :not_found} =
             request(socket, "steer_ack", %Report.SteerAck{
               run_id: theirs.id,
               feedback_id: entry.id
             })
  end

  test "a join pushes unacknowledged steering again, by sent_at (scenario)", ctx do
    run = running(ctx)
    [a, b, c] = for text <- ["first", "second", "acked"], do: record(ctx, text)
    now = DateTime.utc_now()
    pushed!(ctx, run, b, DateTime.add(now, -10, :second))
    pushed!(ctx, run, a, DateTime.add(now, -5, :second))
    pushed!(ctx, run, c, DateTime.add(now, -20, :second), now)

    _socket = joined(ctx, [run.id])

    assert %Push.Steer{feedback_id: first, text: text} = next_steer()
    assert first == b.id
    assert text =~ "> second"
    assert %Push.Steer{feedback_id: second} = next_steer()
    assert second == a.id
    refute_push "steer", _payload
  end

  test "no push again for runs not running or not listed in the join", ctx do
    cancelling = running(ctx, :cancelling)
    unlisted = running(ctx)
    e1 = record(ctx, "one")
    e2 = record(ctx, "two")
    pushed!(ctx, cancelling, e1, DateTime.utc_now())
    pushed!(ctx, unlisted, e2, DateTime.utc_now())

    _socket = joined(ctx, [cancelling.id])

    assert_push "cancel", _payload
    refute_push "steer", _payload
  end
end
