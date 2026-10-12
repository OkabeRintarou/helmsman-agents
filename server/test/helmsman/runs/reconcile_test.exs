defmodule Helmsman.Runs.ReconcileTest do
  # add-run-lifecycle 3.4: heartbeats and joins reconcile the daemon's runs
  # (decision 8).
  use Helmsman.DataCase, async: true
  use Oban.Testing, repo: Helmsman.Repo

  import Helmsman.AgentsFixtures
  import Helmsman.RunsFixtures

  alias Helmsman.Runs
  alias Helmsman.Runs.Run
  alias Helmsman.Runs.Workers.Retry

  setup do
    ctx = dispatch_fixture()
    Repo.update_all(from(p in Helmsman.Agents.AgentProfile), set: [max_concurrency: 10])
    daemon = daemon_of(ctx.agent)
    Map.merge(ctx, %{daemon: daemon, dctx: daemon_ctx(daemon)})
  end

  defp active(ctx, status, seconds_ago \\ 120) do
    run_fixture(ctx.agent, %{
      status: status,
      daemon_id: ctx.daemon.id,
      claimed_at: DateTime.add(DateTime.utc_now(), -seconds_ago, :second)
    })
  end

  defp reload(run), do: Repo.get!(Run, run.id)

  test "a restarted daemon joins with no runs: they fail and are retried (scenario)", ctx do
    runs = [active(ctx, :running), active(ctx, :running, 5)]

    assert {:ok, %{terminate_run_ids: [], cancel_run_ids: []}} =
             Runs.reconcile(ctx.dctx, [], :join)

    for run <- runs do
      assert %Run{status: :failed, failure_reason: :daemon_restart} = reload(run)
      assert_enqueued(worker: Retry, args: %{run_id: run.id})
      assert {:ok, :retried} = Runs.Retry.perform(run.id)
    end

    retries = Repo.all(from(r in Run, where: r.retry_of_id in ^Enum.map(runs, & &1.id)))
    assert length(retries) == 2
    assert Enum.all?(retries, &(&1.status == :queued and &1.attempt == 2))
  end

  test "heartbeat grace: a run claimed 20 seconds ago is left alone (scenario)", ctx do
    fresh = active(ctx, :claimed, 20)
    old = active(ctx, :claimed, 90)
    cancelling = active(ctx, :cancelling, 90)

    assert {:ok, %{terminate_run_ids: []}} = Runs.reconcile(ctx.dctx, [], :heartbeat)
    assert reload(fresh).status == :claimed
    assert %Run{status: :failed, failure_reason: :daemon_restart} = reload(old)
    assert %Run{status: :cancelled} = reload(cancelling)
  end

  test "reported runs that are another daemon's, ended or unknown are to be terminated", ctx do
    {other, _token} = daemon_fixture(ctx.alice, %{workspace_ids: [ctx.workspace.id]})
    mine = active(ctx, :running)
    ended = active(ctx, :succeeded)

    theirs =
      run_fixture(ctx.agent, %{
        status: :running,
        daemon_id: other.id,
        claimed_at: DateTime.utc_now()
      })

    reported = [mine.id, ended.id, theirs.id, 999_999_999]

    assert {:ok, %{terminate_run_ids: terminate}} =
             Runs.reconcile(ctx.dctx, reported, :heartbeat)

    assert Enum.sort(terminate) == Enum.sort([ended.id, theirs.id, 999_999_999])
    assert reload(mine).status == :running
    assert reload(theirs).status == :running
  end

  test "reported cancelling runs get their cancel again", ctx do
    cancelling = active(ctx, :cancelling)
    running = active(ctx, :running)

    assert {:ok, %{cancel_run_ids: [id], terminate_run_ids: []}} =
             Runs.reconcile(ctx.dctx, [cancelling.id, running.id], :heartbeat)

    assert id == cancelling.id
    assert reload(cancelling).status == :cancelling
  end
end
