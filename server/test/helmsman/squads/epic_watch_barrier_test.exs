defmodule Helmsman.Squads.EpicWatchBarrierTest do
  # improve-squad-leader-orchestration 2.2: a run's terminal transaction
  # takes no task row lock for the watchdog (decision 11). Real connections.
  use ExUnit.Case, async: false

  import Ecto.Query
  import Helmsman.OrchestrationFixtures
  import Helmsman.RunLifecycleFixtures
  import Helmsman.RunsFixtures

  alias Helmsman.{CommittedData, Feedback, LockHarness, Repo, Runs}
  alias Helmsman.Runs.Run
  alias HelmsmanProtocol.Report.Finished

  @moduletag timeout: 60_000

  setup do
    ctx =
      CommittedData.unboxed(fn ->
        ctx = orchestration_fixture()
        Repo.update_all(from(r in Run, where: r.status == :running), set: [status: :succeeded])
        daemon = daemon_of(ctx.fe)

        run =
          run_fixture(ctx.fe, %{
            task_id: ctx.s1.id,
            status: :running,
            daemon_id: daemon.id,
            claimed_at: DateTime.utc_now(),
            started_at: DateTime.utc_now()
          })

        Map.put(ctx, :run, run)
      end)

    on_exit(fn -> CommittedData.delete_user_data!([ctx.alice.id, ctx.bob.id, ctx.carol.id]) end)
    ctx
  end

  test "A ends a step's run holding the run row, B writes on the epic holding its row", ctx do
    {:ok, report} = Finished.new(%{run_id: ctx.run.id, status: :succeeded})

    ending =
      LockHarness.start(
        fn -> {:ok, Runs.finish(dctx(ctx.fe), report)} end,
        pause: :commit
      )

    LockHarness.await_paused(ending)

    writing =
      LockHarness.start(fn ->
        Feedback.add(ctx.alice_scope, ctx.epic.ident, %{content: "Status?"})
      end)

    started = System.monotonic_time(:millisecond)
    LockHarness.continue(ending)
    assert {:ok, :ok} = LockHarness.result(ending)
    assert {:ok, _} = LockHarness.result(writing)
    assert System.monotonic_time(:millisecond) - started < 5_000

    CommittedData.unboxed(fn ->
      assert Repo.exists?(
               from(j in Oban.Job,
                 where:
                   j.worker == "Helmsman.Squads.Workers.EpicWatch" and
                     j.args["epic_id"] == ^ctx.epic.id
               )
             )
    end)
  end
end
