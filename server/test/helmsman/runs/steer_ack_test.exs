defmodule Helmsman.Runs.SteerAckTest do
  # add-run-steering 1.4: the daemon's receipt (decision 6) — run-steering
  # 「送达回执」.
  use Helmsman.DataCase, async: true

  import Helmsman.AgentsFixtures
  import Helmsman.ProjectsFixtures
  import Helmsman.RunLifecycleFixtures, only: [running_run!: 2, dctx: 1]
  import Helmsman.RunsFixtures

  alias Helmsman.{Events, Feedback, Runs}
  alias Helmsman.Runs.{Run, RunSteer}
  import ExUnit.CaptureLog

  setup do
    ctx = dispatch_fixture()
    task = task_fixture(ctx.alice_scope, ctx.project.key)
    run = running_run!(ctx.agent, %{task_id: task.id})

    {:ok, entry} =
      Feedback.add(ctx.alice_scope, task.ident, %{content: "Steer", steer_run_id: run.id})

    :ok = Events.subscribe(Events.topic(:task, task.id))
    Map.merge(ctx, %{task: task, run: run, entry: entry})
  end

  defp row(ctx), do: Repo.get_by!(RunSteer, run_id: ctx.run.id, feedback_id: ctx.entry.id)

  defp set_status(run, status),
    do: Repo.update_all(from(r in Run, where: r.id == ^run.id), set: [status: status])

  test "a receipt is recorded and notified once (scenario: repeated)", ctx do
    assert :ok = Runs.steer_ack(dctx(ctx.agent), ctx.run.id, ctx.entry.id)
    %RunSteer{acked_at: %DateTime{} = acked_at} = row(ctx)
    run_id = ctx.run.id
    entry_id = ctx.entry.id
    assert_receive {:steer_acked, %{feedback_id: ^entry_id, run_id: ^run_id}}

    assert :ok = Runs.steer_ack(dctx(ctx.agent), ctx.run.id, ctx.entry.id)
    assert row(ctx).acked_at == acked_at
    assert Repo.aggregate(RunSteer, :count) == 1
    refute_receive {:steer_acked, _}

    assert %{acked_at: ^acked_at} =
             Feedback.view(Feedback.load(Repo.reload!(ctx.entry), ctx.task.ident) |> hd()).steer
  end

  test "accepted while cancelling", ctx do
    set_status(ctx.run, :cancelling)
    assert :ok = Runs.steer_ack(dctx(ctx.agent), ctx.run.id, ctx.entry.id)
    assert %DateTime{} = row(ctx).acked_at
  end

  test "the run already failed (scenario): wrong_state, nothing recorded", ctx do
    Repo.update_all(from(r in Run, where: r.id == ^ctx.run.id),
      set: [status: :failed, failure_reason: :runtime_offline]
    )

    assert {:error, :wrong_state} = Runs.steer_ack(dctx(ctx.agent), ctx.run.id, ctx.entry.id)
    assert row(ctx).acked_at == nil
    refute_receive {:steer_acked, _}
  end

  test "another daemon: not_found", ctx do
    {other, _token} = daemon_fixture(ctx.alice, %{workspace_ids: [ctx.workspace.id]})

    assert {:error, :not_found} =
             Runs.steer_ack(daemon_ctx(other), ctx.run.id, ctx.entry.id)

    assert row(ctx).acked_at == nil
  end

  test "a record never pushed to the run: ok, nothing changes, no notification", ctx do
    {:ok, plain} = Feedback.add(ctx.alice_scope, ctx.task.ident, %{content: "not steered"})

    log =
      capture_log(fn ->
        assert :ok = Runs.steer_ack(dctx(ctx.agent), ctx.run.id, plain.id)
      end)

    assert log =~ "never pushed"
    assert Repo.aggregate(RunSteer, :count) == 1
    assert row(ctx).acked_at == nil
    refute_receive {:steer_acked, _}
  end

  test "a revoked daemon is reauthorized", ctx do
    daemon = daemon_of(ctx.agent)

    Repo.update_all(from(d in Helmsman.Daemons.Daemon, where: d.id == ^daemon.id),
      set: [revoked_at: DateTime.utc_now()]
    )

    assert {:error, :reauthorized} =
             Runs.steer_ack(daemon_ctx(daemon), ctx.run.id, ctx.entry.id)
  end
end
