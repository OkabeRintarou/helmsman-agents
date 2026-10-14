defmodule HelmsmanDaemon.RunsTest do
  use HelmsmanDaemon.Case
  use Slipstream.SocketTest
  @moduletag :tmp_dir
  require Slipstream.Signatures
  alias HelmsmanDaemon.{Connection, StateStore}

  setup do
    start_supervised!({TestReporter, owner: self()})

    {:ok, sup} =
      HelmsmanDaemon.start_daemon(
        test_mode?: true,
        credentials: credentials(),
        reporter: TestReporter,
        stop: fn _ -> :ok end,
        heartbeat_interval_ms: 100_000,
        rotation_interval_ms: 100_000
      )

    Process.unlink(sup)
    on_exit(fn -> if Process.alive?(sup), do: Supervisor.stop(sup) end)
    %{sup: sup}
  end

  defp run_with_child(id, dir) do
    file = Path.join(dir, "child-#{id}")
    run = spec(id, "child")
    run = %{run | agent: %{run.agent | env: %{"FAKE_CLI_CHILD_PID_FILE" => file}}}

    {:ok, worker} =
      Runs.start_run(run, reporter: TestReporter, kill_timeout_ms: 100, report_resubmit_ms: 200)

    assert_receive {:report, ^id, %Report.Started{}, _, _, _}, 1_000
    eventually(fn -> File.exists?(file) end)
    child = File.read!(file) |> String.trim() |> String.to_integer()
    {:ok, record} = StateStore.read(id)
    {worker, record["os_pid"], child}
  end

  test "worker crash kills group, reports unknown, frees slot and never restarts", %{tmp_dir: dir} do
    {worker, pid, child} = run_with_child(1, dir)
    assert Runs.free_slots() == 3
    Process.exit(worker, :kill)

    assert_receive {:report, 1, %Report.Finished{status: :failed, failure_reason: :unknown}, _, _,
                    _},
                   2_000

    eventually(fn -> not alive?(pid) and not alive?(child) end)
    eventually(fn -> Runs.free_slots() == 4 end)
    assert Runs.active() == []
    refute File.exists?(Paths.record(1))
    assert File.ls!(Paths.run(1)) == ["raw.log"]
    refute_receive {:report, 1, %Report.Started{}, _, _, _}
  end

  test "Runs restart monitors live workers; cancel lookup and crash handling survive", %{
    tmp_dir: dir
  } do
    {worker, pid, child} = run_with_child(2, dir)
    previous = Process.whereis(Runs)
    Process.exit(previous, :kill)
    eventually(fn -> is_pid(Process.whereis(Runs)) and Process.whereis(Runs) != previous end)
    assert [%{run_id: 2}] = Runs.active()
    assert Runs.free_slots() == 3
    Process.exit(worker, :kill)
    assert_receive {:report, 2, %Report.Finished{failure_reason: :unknown}, _, _, _}, 2_000
    eventually(fn -> not alive?(pid) and not alive?(child) end)
    {:ok, other} = Runs.start_run(spec(3, "stalled"), reporter: TestReporter)
    assert_receive {:report, 3, %Report.Started{}, _, _, _}, 1_000
    Runs.terminate(3)
    eventually(fn -> not Process.alive?(other) end)
  end

  test "worker dies in Runs restart window; orphan records reconcile without finished", %{
    sup: sup,
    tmp_dir: dir
  } do
    {worker, pid, child} = run_with_child(4, dir)
    :ok = Supervisor.terminate_child(sup, Runs)
    Process.exit(worker, :kill)
    eventually(fn -> not Process.alive?(worker) end)
    {:ok, _} = Supervisor.restart_child(sup, Runs)

    eventually(fn ->
      not alive?(pid) and not alive?(child) and not File.exists?(Paths.record(4))
    end)

    assert Runs.active() == []
    refute File.exists?(Paths.record(4))
    assert File.ls!(Paths.run(4)) == ["raw.log"]
    refute_receive {:report, 4, %Report.Finished{}, _, _, _}
  end

  test "worker dies before CLI launch; record cleans private directory", %{sup: sup} do
    TestReporter.configure(fn _ -> :hold end)
    {:ok, worker} = Runs.start_run(spec(5), reporter: TestReporter)
    assert_receive {:report, 5, %Report.Starting{}, _, _, _}, 1_000
    assert File.exists?(Path.join(Paths.run(5), "tmp"))
    :ok = Supervisor.terminate_child(sup, Runs)
    Process.exit(worker, :kill)
    eventually(fn -> not Process.alive?(worker) end)
    # Registry removes dead workers asynchronously. Reconciliation's live
    # inventory must no longer contain the worker before Runs restarts.
    eventually(fn -> Registry.lookup(HelmsmanDaemon.RunRegistry, 5) == [] end)
    {:ok, _} = Supervisor.restart_child(sup, Runs)
    refute File.exists?(Paths.run(5))
    refute File.exists?(Paths.record(5))
  end

  test "Connection restart causes worker to resubmit the same unacknowledged events" do
    client = Process.whereis(Connection)
    accept_connect(client)

    assert_join(
      "daemon:1",
      _,
      {:ok, %{"daemon_id" => 1, "runtimes" => [], "terminate_run_ids" => []}},
      1_000
    )

    assert_push("daemon:1", "claim", %{}, claim_ref, 1_000)
    reply(client, claim_ref, {:ok, %{"runs" => []}})

    {:ok, worker} =
      Runs.start_run(spec(6, "stalled"), reporter: Connection, report_resubmit_ms: 200)

    assert_push("daemon:1", "starting", _, start_ref, 1_000)
    reply(client, start_ref, {:ok, %{"action" => "proceed", "reason" => nil}})
    assert_push("daemon:1", "started", _, started_ref, 1_000)
    reply(client, started_ref, {:ok, %{}})
    assert_push("daemon:1", "events", wire, _, 2_000)
    Process.exit(client, :kill)

    eventually(fn ->
      is_pid(Process.whereis(Connection)) and Process.whereis(Connection) != client
    end)

    next = Process.whereis(Connection)
    accept_connect(next)

    assert_join(
      "daemon:1",
      join,
      {:ok, %{"daemon_id" => 1, "runtimes" => [], "terminate_run_ids" => []}},
      1_000
    )

    assert [%{"run_id" => 6}] = join["active_runs"]
    assert_push("daemon:1", "claim", %{}, ref, 1_000)
    reply(next, ref, {:ok, %{"runs" => []}})
    assert_push("daemon:1", "events", retry, events_ref, 2_000)
    assert retry == wire
    reply(next, events_ref, {:ok, %{"acked_seq" => 1}})
    Runs.terminate(6)
    eventually(fn -> not Process.alive?(worker) end)
  end
end
