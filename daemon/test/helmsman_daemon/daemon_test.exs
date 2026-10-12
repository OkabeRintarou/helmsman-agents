defmodule HelmsmanDaemon.DaemonTest do
  use HelmsmanDaemon.Case
  use Slipstream.SocketTest
  @moduletag :tmp_dir
  alias HelmsmanDaemon.{Connection, Exec, StateStore}
  import ExUnit.CaptureIO

  test "explicit startup launches dependency tree and prints notice once" do
    opts = [test_mode?: true, credentials: credentials(), stop: fn _ -> :ok end]

    output =
      capture_io(fn ->
        {:ok, sup} = HelmsmanDaemon.start_daemon(opts)

        for name <- [
              HelmsmanDaemon.Config,
              StateStore,
              HelmsmanDaemon.Detector,
              HelmsmanDaemon.RunRegistry,
              HelmsmanDaemon.RunSupervisor,
              Runs,
              Connection,
              HelmsmanDaemon.Janitor
            ] do
          assert is_pid(Process.whereis(name))
        end

        Supervisor.stop(sup)
      end)

    assert output =~ "GitHub"
    assert output =~ "系统用户"

    output =
      capture_io(fn ->
        {:ok, sup} = HelmsmanDaemon.start_daemon(opts)
        Supervisor.stop(sup)
      end)

    assert output == ""
  end

  test "startup recovers process group before joining with empty active runs" do
    {:ok, _, pid} =
      :exec.run(["/bin/sh", "-c", "sleep 600 & sleep 600"], [{:group, 0}, :kill_group])

    on_exit(fn -> Exec.signal_group(pid, 9) end)
    {:ok, start} = Exec.proc_start(pid)
    Paths.private_dir!(Path.join(Paths.run(7), "tmp"))
    StateStore.write(7, %{os_pid: pid, pgid: pid, proc_start: start})

    {:ok, sup} =
      HelmsmanDaemon.start_daemon(
        test_mode?: true,
        credentials: credentials(),
        stop: fn _ -> :ok end
      )

    accept_connect(Connection)

    assert_join(
      "daemon:1",
      payload,
      {:ok, %{"daemon_id" => 1, "runtimes" => [], "terminate_run_ids" => []}},
      1_000
    )

    assert payload["active_runs"] == []
    eventually(fn -> not alive?(pid) end)
    refute File.exists?(Paths.record(7))
    refute File.exists?(Paths.run(7))
    assert_push("daemon:1", "claim", %{}, ref, 1_000)
    reply(Connection, ref, {:ok, %{"runs" => []}})
    Supervisor.stop(sup)
  end
end
