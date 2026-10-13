defmodule Helmsman.E2E.DaemonProcessCleanupTest do
  use ExUnit.Case, async: true

  import ExUnit.Callbacks, only: [on_exit: 1]

  alias Helmsman.DaemonE2E

  @supervisor_script Path.expand("../support/daemon_process_supervisor.py", __DIR__)

  @moduletag :e2e
  if :os.type() != {:unix, :linux} do
    @moduletag skip: "daemon E2E tests require Linux"
  end

  @moduletag timeout: 15_000

  test "captured process group is cleaned after its port owner exits" do
    home = Path.join(System.tmp_dir!(), "daemon-cleanup-#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    on_exit(fn -> File.rm_rf!(home) end)

    pid_file = Path.join(home, "child.pid")
    script = Path.join(home, "spawn-child.sh")

    File.write!(script, "#!/bin/sh\nsleep 300 &\nprintf '%s\\n' \"$!\" > \"$PID_FILE\"\nwait\n")
    File.chmod!(script, 0o700)

    port =
      DaemonE2E.start_process("/bin/sh", [script],
        cd: home,
        env: [{~c"PID_FILE", String.to_charlist(pid_file)}],
        registration_delay_ms: 100
      )

    on_exit_kill_recorded_process(pid_file)
    assert {:os_pid, _setsid_pid} = Port.info(port, :os_pid)

    [group_file] =
      home
      |> File.ls!()
      |> Enum.filter(&String.starts_with?(&1, ".helmsman-e2e-pgid-"))
      |> Enum.map(&Path.join(home, &1))

    process_group_id = group_id(group_file)
    child_pid = wait_for_pid_file!(pid_file)
    assert process_group_id(child_pid) == process_group_id
    assert process_running?(child_pid)

    # Closing the port models its owner exiting before the ExUnit cleanup hook.
    _ = Port.close(port)
    :ok = DaemonE2E.stop_daemon(port)

    assert eventually_stopped?(child_pid),
           "child process #{child_pid} survived process-group cleanup"
  end

  test "cleans up a running child when process-group registration times out" do
    home =
      Path.join(
        System.tmp_dir!(),
        "daemon-registration-timeout-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(home)
    on_exit(fn -> File.rm_rf!(home) end)

    pid_file = Path.join(home, "child.pid")
    script = Path.join(home, "exit-early.sh")

    File.write!(script, "#!/bin/sh\nsleep 300 &\nprintf '%s\\n' \"$!\" > \"$PID_FILE\"\nexit 0\n")
    File.chmod!(script, 0o700)

    assert_raise ExUnit.AssertionError, ~r/could not establish daemon process group/, fn ->
      DaemonE2E.start_process("/bin/sh", [script],
        cd: home,
        env: [{~c"PID_FILE", String.to_charlist(pid_file)}],
        registration_delay_ms: 1_100
      )
    end

    child_pid = wait_for_pid_file!(pid_file)

    assert eventually_stopped?(child_pid),
           "child process #{child_pid} survived process-group registration timeout"
  end

  test "keeps ownership when the command leader exits before startup returns" do
    home = Path.join(System.tmp_dir!(), "daemon-early-exit-#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    on_exit(fn -> File.rm_rf!(home) end)

    pid_file = Path.join(home, "child.pid")
    script = Path.join(home, "exit-early.sh")

    File.write!(script, "#!/bin/sh\nsleep 300 &\nprintf '%s\\n' \"$!\" > \"$PID_FILE\"\nexit 0\n")
    File.chmod!(script, 0o700)

    port =
      DaemonE2E.start_process("/bin/sh", [script],
        cd: home,
        env: [{~c"PID_FILE", String.to_charlist(pid_file)}]
      )

    on_exit_kill_recorded_process(pid_file)
    child_pid = wait_for_pid_file!(pid_file)
    assert process_running?(child_pid)

    _ = Port.close(port)
    :ok = DaemonE2E.stop_daemon(port)

    assert eventually_stopped?(child_pid),
           "child process #{child_pid} survived cleanup after its leader exited"
  end

  test "cleans descendants that move into a separate session" do
    home =
      Path.join(System.tmp_dir!(), "daemon-child-session-#{System.unique_integer([:positive])}")

    File.mkdir_p!(home)
    on_exit(fn -> File.rm_rf!(home) end)

    pid_file = Path.join(home, "child.pid")
    script = Path.join(home, "new-session.sh")

    File.write!(
      script,
      "#!/bin/sh\nsetsid /bin/sh -c 'printf \"%s\\n\" \"$$\" > \"$CHILD_FILE\"; exec sleep 300' >/dev/null 2>&1 &\nwait\n"
    )

    File.chmod!(script, 0o700)

    port =
      DaemonE2E.start_process("/bin/sh", [script],
        cd: home,
        env: [{~c"CHILD_FILE", String.to_charlist(pid_file)}]
      )

    on_exit_kill_recorded_process(pid_file)
    child_pid = wait_for_pid_file!(pid_file)
    [group_file] = process_group_files(home)
    refute process_group_id(child_pid) == group_id(group_file)
    assert process_running?(child_pid)

    _ = Port.close(port)
    :ok = DaemonE2E.stop_daemon(port)

    assert eventually_stopped?(child_pid),
           "child process #{child_pid} survived after moving into its own session"
  end

  test "reports cleanup timeout and retains the process group for retry" do
    home =
      Path.join(System.tmp_dir!(), "daemon-cleanup-timeout-#{System.unique_integer([:positive])}")

    File.mkdir_p!(home)
    on_exit(fn -> File.rm_rf!(home) end)

    pid_file = Path.join(home, "child.pid")
    script = Path.join(home, "spawn-child.sh")

    File.write!(script, "#!/bin/sh\nsleep 300 &\nprintf '%s\\n' \"$!\" > \"$PID_FILE\"\nwait\n")
    File.chmod!(script, 0o700)

    port =
      DaemonE2E.start_process("/bin/sh", [script],
        cd: home,
        env: [{~c"PID_FILE", String.to_charlist(pid_file)}]
      )

    on_exit_kill_recorded_process(pid_file)
    child_pid = wait_for_pid_file!(pid_file)
    [group_file] = process_group_files(home)
    supervisor_pid = group_id(group_file)

    assert {"", 0} = System.cmd("kill", ["-STOP", "--", Integer.to_string(supervisor_pid)])

    try do
      assert eventually_stopped_by_signal?(supervisor_pid), "supervisor did not enter SIGSTOP"

      assert_raise RuntimeError, ~r/process_group_exit_timeout/, fn ->
        DaemonE2E.stop_daemon(port)
      end

      process_groups = :persistent_term.get({DaemonE2E, :process_groups}, %{})
      assert Map.has_key?(process_groups, port), "timed-out process group was unregistered"
    after
      System.cmd("kill", ["-CONT", "--", Integer.to_string(supervisor_pid)])
    end

    :ok = DaemonE2E.stop_daemon(port)

    assert eventually_stopped?(child_pid),
           "child process #{child_pid} survived cleanup retry after SIGCONT"
  end

  test "cleans a TERM-resistant child launched from a non-main thread and separate session" do
    home =
      Path.join(
        System.tmp_dir!(),
        "daemon-thread-child-session-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(home)
    on_exit(fn -> File.rm_rf!(home) end)

    pid_file = Path.join(home, "child.pid")
    scan_file = Path.join(home, "thread-child-scan")
    script = Path.join(home, "spawn-thread-child.py")

    File.write!(
      script,
      """
      import importlib.util
      import os
      import signal
      import subprocess
      import sys
      import threading
      import time

      signal.signal(signal.SIGTERM, signal.SIG_IGN)
      spec = importlib.util.spec_from_file_location('daemon_process_supervisor', os.environ['SUPERVISOR_SCRIPT'])
      supervisor = importlib.util.module_from_spec(spec)
      spec.loader.exec_module(supervisor)
      child_code = \"import os, signal, time; signal.signal(signal.SIGTERM, signal.SIG_IGN); open(os.environ['CHILD_PID_FILE'], 'w').write(str(os.getpid())); time.sleep(300)\"

      def launch_child():
          child = subprocess.Popen([sys.executable, '-c', child_code], start_new_session=True)
          child.wait()

      threading.Thread(target=launch_child).start()

      while not os.path.exists(os.environ['CHILD_PID_FILE']):
          time.sleep(0.01)
      child_pid = int(open(os.environ['CHILD_PID_FILE']).read())
      visible = child_pid in supervisor.descendants(os.getpid())
      open(os.environ['SCAN_FILE'], 'w').write('found' if visible else 'missing')

      while True:
          time.sleep(1)
      """
    )

    python =
      System.find_executable("python3") || flunk("python3 is required for daemon e2e tests")

    port =
      DaemonE2E.start_process(python, [script],
        cd: home,
        env: [
          {~c"CHILD_PID_FILE", String.to_charlist(pid_file)},
          {~c"SCAN_FILE", String.to_charlist(scan_file)},
          {~c"SUPERVISOR_SCRIPT", String.to_charlist(@supervisor_script)}
        ]
      )

    on_exit_kill_recorded_process(pid_file)
    wait_for_file!(scan_file)
    assert File.read!(scan_file) == "found", "scanner missed a child of a non-main thread"
    child_pid = wait_for_pid_file!(pid_file)
    [group_file] = process_group_files(home)
    refute process_group_id(child_pid) == group_id(group_file)
    assert process_running?(child_pid)

    _ = Port.close(port)
    :ok = DaemonE2E.stop_daemon(port)

    assert eventually_stopped?(child_pid, System.monotonic_time(:millisecond) + 6_000),
           "TERM-resistant child from a non-main thread survived forced cleanup"
  end

  test "rediscovers a detached descendant created after the first KILL snapshot" do
    home =
      Path.join(System.tmp_dir!(), "daemon-kill-rescan-#{System.unique_integer([:positive])}")

    File.mkdir_p!(home)
    on_exit(fn -> File.rm_rf!(home) end)

    snapshot_file = Path.join(home, "kill-snapshot")
    continue_file = Path.join(home, "continue-kill")
    spawn_file = Path.join(home, "spawn-child")
    ready_file = Path.join(home, "command-ready")
    pid_file = Path.join(home, "child.pid")
    script = Path.join(home, "spawn-after-snapshot.py")

    File.write!(
      script,
      """
      import os
      import signal
      import subprocess
      import sys
      import threading
      import time

      signal.signal(signal.SIGTERM, signal.SIG_IGN)
      child_code = "import os, signal, time; signal.signal(signal.SIGTERM, signal.SIG_IGN); open(os.environ['CHILD_PID_FILE'], 'w').write(str(os.getpid())); time.sleep(300)"

      def wait_and_spawn():
          while not os.path.exists(os.environ['SPAWN_FILE']):
              time.sleep(0.01)
          child = subprocess.Popen([sys.executable, '-c', child_code], start_new_session=True)
          child.wait()

      threading.Thread(target=wait_and_spawn).start()
      open(os.environ['READY_FILE'], 'w').write('ready')

      while True:
          time.sleep(1)
      """
    )

    python =
      System.find_executable("python3") || flunk("python3 is required for daemon e2e tests")

    port =
      DaemonE2E.start_process(python, [script],
        cd: home,
        env: [
          {~c"CHILD_PID_FILE", String.to_charlist(pid_file)},
          {~c"SPAWN_FILE", String.to_charlist(spawn_file)},
          {~c"READY_FILE", String.to_charlist(ready_file)},
          {~c"HELMSMAN_E2E_KILL_SNAPSHOT_FILE", String.to_charlist(snapshot_file)},
          {~c"HELMSMAN_E2E_KILL_CONTINUE_FILE", String.to_charlist(continue_file)}
        ]
      )

    on_exit_kill_recorded_process(pid_file)
    [group_file] = process_group_files(home)
    supervisor_pid = group_id(group_file)
    wait_for_file!(ready_file)
    assert {"", 0} = System.cmd("kill", ["-TERM", "--", "-#{supervisor_pid}"])

    try do
      wait_for_file!(snapshot_file, System.monotonic_time(:millisecond) + 7_000)
      File.write!(spawn_file, "spawn\n")

      child_pid = wait_for_pid_file!(pid_file)
      refute process_group_id(child_pid) == group_id(group_file)
      assert process_running?(child_pid)

      File.write!(continue_file, "continue\n")
      :ok = DaemonE2E.stop_daemon(port)

      assert eventually_stopped?(child_pid),
             "descendant created after the KILL snapshot survived rescan"
    after
      File.write!(continue_file, "continue\n")
      kill_recorded_process(pid_file)
    end
  end

  defp process_group_files(home) do
    home
    |> File.ls!()
    |> Enum.filter(&String.starts_with?(&1, ".helmsman-e2e-pgid-"))
    |> Enum.map(&Path.join(home, &1))
  end

  defp group_id(path) do
    path
    |> File.read!()
    |> String.split()
    |> hd()
    |> String.to_integer()
  end

  defp wait_for_pid_file!(path, deadline \\ System.monotonic_time(:millisecond) + 2_000) do
    path = wait_for_file!(path, deadline)
    path |> File.read!() |> String.trim() |> String.to_integer()
  end

  defp wait_for_file!(path, deadline \\ System.monotonic_time(:millisecond) + 2_000) do
    cond do
      File.exists?(path) ->
        path

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("timed out waiting for #{path}")

      true ->
        Process.sleep(10)
        wait_for_file!(path, deadline)
    end
  end

  defp on_exit_kill_recorded_process(path),
    do: on_exit(fn -> kill_recorded_process(path) end)

  defp kill_recorded_process(path) do
    with {:ok, value} <- File.read(path),
         {pid, ""} when pid > 0 <- Integer.parse(String.trim(value)),
         true <- process_running?(pid) do
      System.cmd("kill", ["-KILL", "--", Integer.to_string(pid)])
    end

    :ok
  end

  defp process_group_id(pid) do
    case System.cmd("ps", ["-o", "pgid=", "-p", Integer.to_string(pid)], stderr_to_stdout: true) do
      {group, 0} -> String.trim(group) |> String.to_integer()
      _ -> nil
    end
  end

  defp process_running?(pid) do
    case System.cmd("ps", ["-o", "stat=", "-p", Integer.to_string(pid)], stderr_to_stdout: true) do
      {state, 0} -> not String.starts_with?(String.trim(state), "Z")
      _ -> false
    end
  end

  defp eventually_stopped_by_signal?(pid, deadline \\ System.monotonic_time(:millisecond) + 2_000) do
    cond do
      process_stopped_by_signal?(pid) ->
        true

      System.monotonic_time(:millisecond) >= deadline ->
        false

      true ->
        Process.sleep(25)
        eventually_stopped_by_signal?(pid, deadline)
    end
  end

  defp process_stopped_by_signal?(pid) do
    case System.cmd("ps", ["-o", "stat=", "-p", Integer.to_string(pid)], stderr_to_stdout: true) do
      {state, 0} -> String.starts_with?(String.trim(state), "T")
      _ -> false
    end
  end

  defp eventually_stopped?(pid, deadline \\ System.monotonic_time(:millisecond) + 3_000) do
    cond do
      not process_running?(pid) ->
        true

      System.monotonic_time(:millisecond) >= deadline ->
        false

      true ->
        Process.sleep(25)
        eventually_stopped?(pid, deadline)
    end
  end
end
