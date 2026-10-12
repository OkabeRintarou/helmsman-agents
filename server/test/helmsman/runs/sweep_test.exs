defmodule Helmsman.Runs.SweepTest do
  # add-run-lifecycle 4.3: the minute sweep of leases and offline daemons
  # (decision 16).
  use Helmsman.DataCase, async: true
  use Oban.Testing, repo: Helmsman.Repo

  import Helmsman.RunsFixtures

  alias Helmsman.Daemons.Daemon
  alias Helmsman.Runs.{Run, RunTokens}
  alias Helmsman.Runs.Workers.{Retry, Sweep}

  setup do
    ctx = dispatch_fixture()
    Repo.update_all(from(p in Helmsman.Agents.AgentProfile), set: [max_concurrency: 10])
    Map.put(ctx, :daemon, daemon_of(ctx.agent))
  end

  defp active(ctx, status, claimed_seconds_ago) do
    run_fixture(ctx.agent, %{
      status: status,
      daemon_id: ctx.daemon.id,
      claimed_at: DateTime.add(DateTime.utc_now(), -claimed_seconds_ago, :second),
      triggers: [trigger("manual", ctx.workspace, ctx.alice, ctx.agent)]
    })
  end

  defp reload(run), do: Repo.get!(Run, run.id)

  defp set_daemon(ctx, changes),
    do: Repo.update_all(from(d in Daemon, where: d.id == ^ctx.daemon.id), set: changes)

  test "a lease that expired: failed, requeued with the same triggers, not counted (scenario)",
       ctx do
    expired = active(ctx, :claimed, 11 * 60)
    {:ok, token} = RunTokens.issue(expired)
    fresh = active(ctx, :claimed, 9 * 60)
    running = active(ctx, :running, 60 * 60)

    assert :ok = perform_job(Sweep, %{})

    assert %Run{status: :failed, failure_reason: :lease_expired, finished_at: %DateTime{}} =
             reload(expired)

    assert RunTokens.authenticate(token) == {:error, :unauthorized}
    assert reload(fresh).status == :claimed
    assert reload(running).status == :running

    assert_enqueued(worker: Retry, args: %{run_id: expired.id})
    assert :ok = perform_job(Retry, %{run_id: expired.id})
    retry = Repo.get_by!(Run, retry_of_id: expired.id)
    assert %Run{status: :queued, attempt: 1, auto_retries: 0} = retry
    assert hd(retry.triggers) == hd(expired.triggers)
  end

  for {name, changes} <- [
        {"silent for over 2 minutes", [last_seen_at: :old]},
        {"revoked", [revoked_at: :now]}
      ] do
    @changes changes
    test "an offline daemon (#{name}): its runs fail, cancelling ones are cancelled", ctx do
      claimed = active(ctx, :claimed, 30)
      running = active(ctx, :running, 30)
      cancelling = active(ctx, :cancelling, 30)

      Repo.update_all(from(r in Run, where: r.id == ^cancelling.id),
        set: [failure_reason: :unauthorized]
      )

      now = DateTime.utc_now(:second)

      set_daemon(
        ctx,
        Enum.map(@changes, fn
          {key, :old} -> {key, DateTime.add(now, -180, :second)}
          {key, :now} -> {key, now}
        end)
      )

      assert :ok = perform_job(Sweep, %{})

      for run <- [claimed, running] do
        assert %Run{status: :failed, failure_reason: :runtime_offline} = reload(run)
        assert_enqueued(worker: Retry, args: %{run_id: run.id})
      end

      assert %Run{status: :cancelled, failure_reason: :unauthorized} = reload(cancelling)
    end
  end

  test "a daemon seen 90 seconds ago is online", ctx do
    run = active(ctx, :running, 30)
    set_daemon(ctx, last_seen_at: DateTime.add(DateTime.utc_now(:second), -90, :second))
    assert :ok = perform_job(Sweep, %{})
    assert reload(run).status == :running
  end
end

defmodule Helmsman.Runs.SweepRaceTest do
  # add-run-lifecycle 4.3 and decision 27: the sweep judges again under the
  # run row lock; ending a run (sweep, starting's abort) makes a run-token
  # write that waits on a lock fail with `run_ended`.
  use ExUnit.Case, async: false
  use Oban.Testing, repo: Helmsman.Repo

  import Ecto.Query
  import Helmsman.ProjectsFixtures
  import Helmsman.RunsFixtures

  alias Helmsman.{CommittedData, LockHarness, Repo, Runs, Tasks}
  alias Helmsman.Daemons.Daemon
  alias Helmsman.Projects.Project
  alias Helmsman.Runs.{Run, RunTokens}
  alias Helmsman.Runs.Workers.Sweep
  alias HelmsmanProtocol.Report

  setup do
    ctx =
      CommittedData.unboxed(fn ->
        ctx = dispatch_fixture()
        daemon = daemon_of(ctx.agent)
        task = task_fixture(ctx.alice_scope, ctx.project.key)

        run =
          run_fixture(ctx.agent, %{
            task_id: task.id,
            status: :running,
            daemon_id: daemon.id,
            claimed_at: DateTime.utc_now(),
            capabilities: ["read", "write_task", "create_tasks"]
          })

        {:ok, token} = RunTokens.issue(run)
        Map.merge(ctx, %{daemon: daemon, task: task, run: run, token: token})
      end)

    on_exit(fn -> CommittedData.delete_user_data!([ctx.alice.id]) end)
    ctx
  end

  defp silence(ctx) do
    CommittedData.unboxed(fn ->
      Repo.update_all(from(d in Daemon, where: d.id == ^ctx.daemon.id),
        set: [last_seen_at: DateTime.add(DateTime.utc_now(:second), -600, :second)]
      )
    end)
  end

  defp status(ctx),
    do: CommittedData.unboxed(fn -> Repo.get!(Run, ctx.run.id).status end)

  test "a finish that commits after the candidates were read wins", ctx do
    silence(ctx)
    sweep = LockHarness.start(fn -> perform_job(Sweep, %{}) end, pause: :sweep_candidates)
    LockHarness.await_paused(sweep)

    {:ok, report} = Report.Finished.new(%{run_id: ctx.run.id, status: :succeeded})
    assert :ok = CommittedData.unboxed(fn -> Runs.finish(daemon_ctx(ctx.daemon), report) end)

    LockHarness.continue(sweep)
    assert :ok = LockHarness.result(sweep)
    assert status(ctx) == :succeeded
  end

  # The write (creating a task) waits on the project row; the run ends
  # meanwhile.
  defp assert_write_refused(ctx, end_run) do
    {:ok, scope} = CommittedData.unboxed(fn -> RunTokens.scope(ctx.token) end)

    locker =
      LockHarness.start(
        fn ->
          Repo.one!(from(p in Project, where: p.id == ^ctx.project.id, lock: "FOR UPDATE"))
        end,
        pause: :commit
      )

    LockHarness.await_paused(locker)
    writer = LockHarness.start(fn -> Tasks.create(scope, ctx.project.key, %{title: "late"}) end)
    LockHarness.await_blocked(writer)

    end_run.()
    LockHarness.continue(locker)
    LockHarness.result(locker)
    assert LockHarness.result(writer) == {:error, :run_ended}
  end

  test "the sweep ends the run (runtime_offline): a waiting run-token write is refused", ctx do
    silence(ctx)

    assert_write_refused(ctx, fn ->
      assert :ok = CommittedData.unboxed(fn -> perform_job(Sweep, %{}) end)
      assert status(ctx) == :failed
    end)
  end

  test "starting aborts the run: a waiting run-token write is refused", ctx do
    CommittedData.unboxed(fn ->
      Repo.update_all(from(r in Run, where: r.id == ^ctx.run.id), set: [status: :claimed])

      Repo.update_all(from(p in Helmsman.Agents.AgentProfile, where: p.actor_id == ^ctx.agent.id),
        set: [archived_at: DateTime.utc_now(:second)]
      )
    end)

    assert_write_refused(ctx, fn ->
      assert {:ok, {:abort, "obsolete"}} =
               CommittedData.unboxed(fn -> Runs.starting(daemon_ctx(ctx.daemon), ctx.run.id) end)
    end)
  end
end
