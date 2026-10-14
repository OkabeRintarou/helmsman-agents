defmodule HelmsmanDaemon.RunWorkerDescendantsTest do
  @moduledoc "daemon-runner: descendants that leave the process group (add-cursor-adapter decision 10)."
  use HelmsmanDaemon.Case
  @moduletag :tmp_dir
  if :os.type() != {:unix, :linux}, do: @moduletag(:skip)

  import HelmsmanDaemon.GitHelpers
  alias HelmsmanDaemon.Adapters.TrackingFake
  alias HelmsmanDaemon.{Detector, GitWorkspace, ProcGroup, ProcScan, StateStore}

  @success ~s(json {"type":"result","data":{"text":"done","success":true}}\n)
  @helper Path.expand("../support/fake_cli/nondumpable.py", __DIR__)
  @wait_log ~s(sh while [ ! -s orphan.log ]; do sleep 0.01; done\n)
  @wait_pid ~s(sh while [ ! -s "$FAKE_CLI_CHILD_PID_FILE" ]; do sleep 0.01; done\n)

  setup %{tmp_dir: dir} do
    on_exit(fn -> stop_recorded(dir) end)
    %{pid_file: Path.join(dir, "child.pid")}
  end

  # Only the processes these tests started, by the PIDs they recorded.
  defp stop_recorded(dir) do
    for file <- Path.wildcard(Path.join(dir, "*.pid")),
        {pid, ""} <- [Integer.parse(String.trim(File.read!(file)))],
        do: System.cmd("kill", ["-9", to_string(pid)], stderr_to_stdout: true)
  end

  defp run(id, instructions, pid_file, opts \\ []) do
    {repo, opts} = Keyword.pop(opts, :repo)
    run = if repo, do: repo_spec(repo, id), else: spec(id)
    scenario = scenario!(Path.join(Paths.home(), "scenario-#{id}"), instructions)

    env = %{"FAKE_CLI_CHILD_PID_FILE" => pid_file, "ND_HELPER" => @helper}
    run = %{run | agent: %{run.agent | custom_args: [scenario], env: env}}

    opts =
      Keyword.merge(
        [
          adapter: TrackingFake,
          reporter: TestReporter,
          allow_file_urls: true,
          push_backoff_ms: [0, 0],
          kill_timeout_ms: 200
        ],
        opts
      )

    {:ok, worker} = Runs.start_run(run, opts)
    {worker, run}
  end

  defp pid!(file) do
    eventually(fn -> File.exists?(file) and File.read!(file) != "" end, 1_000)
    file |> File.read!() |> String.trim() |> String.to_integer()
  end

  defp finished(id) do
    assert_receive {:report, ^id, %Report.Finished{} = payload, _, _, _}, 15_000
    payload
  end

  defp orphan(loop),
    do:
      ~s(sh setsid sh -c 'echo $$ > "$FAKE_CLI_CHILD_PID_FILE"; #{loop}' </dev/null >/dev/null 2>&1 &\n)

  describe "with tracking" do
    setup do
      start_execution()
      :ok
    end

    test "a setsid child started after the last snapshot ends before git finalization", %{
      tmp_dir: dir,
      pid_file: pid_file
    } do
      fixture = fixture(dir)
      loop = "while :; do echo x >> orphan.log; sleep 0.05; done"

      {_, run} =
        run(41, "sleep 0.3\n" <> orphan(loop) <> @wait_pid <> @wait_log <> @success, pid_file,
          repo: fixture,
          snapshot_interval_ms: 50
        )

      child = pid!(pid_file)
      assert_receive {:report, 41, %Report.Pushed{head_sha: head}, _, _, _}, 15_000
      refute alive?(child)
      payload = finished(41)
      assert payload.status == :succeeded
      assert payload.error == nil

      log = Path.join(GitWorkspace.worktree_path(run), "orphan.log")
      written = File.read!(log)
      Process.sleep(300)
      assert File.read!(log) == written
      assert git!(fixture.git, fixture.remote, ["show", head <> ":orphan.log"]) <> "\n" == written
      eventually(fn -> not File.exists?(Paths.record(41)) end)
    end

    test "a stopped run ends its setsid child first; untagged processes are left alone", %{
      pid_file: pid_file,
      tmp_dir: dir
    } do
      {_, _} =
        run(42, orphan("while :; do sleep 0.05; done") <> "out started\nsleep 600\n", pid_file)

      child = pid!(pid_file)
      assert_receive {:report, 42, %Report.Started{}, _, _, _}

      # Same user, started during the run, without the tag.
      {control, 0} = System.cmd("sh", ["-c", "sleep 30 >/dev/null 2>&1 & echo $!"])
      control = String.trim(control)
      File.write!(Path.join(dir, "control.pid"), control)

      Runs.cancel(42)
      payload = finished(42)
      refute alive?(child)
      assert payload.status == :cancelled
      assert alive?(control)
      eventually(fn -> not File.exists?(Paths.record(42)) end)
    end

    test "a setsid child ignoring SIGTERM is killed before finished", %{pid_file: pid_file} do
      {_, _} =
        run(
          43,
          orphan(~s[trap "" TERM; while :; do sleep 0.05; done]) <>
            @wait_pid <> "out started\nsleep 600\n",
          pid_file
        )

      child = pid!(pid_file)
      assert_receive {:report, 43, %Report.Started{}, _, _, _}
      stopped = System.monotonic_time(:millisecond)
      Runs.cancel(43)
      payload = finished(43)
      assert System.monotonic_time(:millisecond) - stopped >= 200
      refute alive?(child)
      assert payload.status == :cancelled
    end

    test "an unreadable unlinked descendant is never signalled and keeps the barrier", %{
      tmp_dir: dir,
      pid_file: pid_file
    } do
      fixture = fixture(dir)

      spawn =
        ~s(sh setsid sh -c 'python3 "$ND_HELPER" "$FAKE_CLI_CHILD_PID_FILE" $$ & exit 0' </dev/null >/dev/null 2>&1 &\n)

      {_, _} =
        run(44, spawn <> @wait_pid <> "write hello\n" <> @success, pid_file,
          repo: fixture,
          kill_timeout_ms: 50,
          group_cleanup_timeout_ms: 300
        )

      child = pid!(pid_file)
      payload = finished(44)
      assert alive?(child)
      assert payload.error =~ "descendant cleanup uncertain: pid #{child} (python3)"
      refute_received {:report, 44, %Report.Pushed{}, _, _, _}
      assert File.exists?(Paths.record(44))
    end

    test "an adapter without tracking leaves a setsid child as before", %{pid_file: pid_file} do
      alias HelmsmanDaemon.Adapters.Fake
      {_, _} = run(40, orphan("exec sleep 30") <> @wait_pid <> @success, pid_file, adapter: Fake)
      child = pid!(pid_file)
      payload = finished(40)
      assert payload.status == :succeeded
      assert alive?(child)
    end

    test "an unreadable process in a member's session is a member", %{pid_file: pid_file} do
      spawn =
        ~s(sh setsid sh -c 'python3 "$ND_HELPER" "$FAKE_CLI_CHILD_PID_FILE" & exec sleep 30' </dev/null >/dev/null 2>&1 &\n)

      {_, _} = run(45, spawn <> @wait_pid <> @success, pid_file, kill_timeout_ms: 50)
      child = pid!(pid_file)
      payload = finished(45)
      refute alive?(child)
      assert payload.status == :succeeded
      assert payload.error == nil
    end

    test "after the session leader exits, a live member's session still links", %{
      pid_file: pid_file
    } do
      spawn =
        ~s(sh setsid sh -c 'python3 "$ND_HELPER" "$FAKE_CLI_CHILD_PID_FILE" & sleep 30 </dev/null >/dev/null 2>&1 & exit 0' </dev/null >/dev/null 2>&1 &\n)

      {_, _} = run(54, spawn <> @wait_pid <> @success, pid_file, kill_timeout_ms: 50)
      child = pid!(pid_file)
      payload = finished(54)
      refute alive?(child)
      assert payload.status == :succeeded
      assert payload.error == nil
    end

    test "an unreadable process older than the CLI does not hold the barrier", %{
      tmp_dir: dir,
      pid_file: pid_file
    } do
      older = Path.join(dir, "older.pid")

      port =
        Port.open({:spawn_executable, System.find_executable("python3")}, args: [@helper, older])

      older_pid = pid!(older)
      {:ok, older_info} = ProcScan.stat(File.read!("/proc/#{older_pid}/stat"))
      # The cleanup lower bound subtracts one tick. Ensure this process
      # really predates that bound, even on a fast or warmed test runner.
      eventually(fn -> ProcScan.now_ticks() > older_info.start end)

      {_, _} = run(46, @success, pid_file)
      payload = finished(46)
      assert payload.status == :succeeded
      assert payload.error == nil
      assert alive?(older_pid)
      Port.close(port)
    end
  end

  test "crash recovery ends the recorded run's tagged descendants", %{pid_file: pid_file} do
    tag = ProcScan.new_tag(47)
    since = ProcScan.now_ticks()

    {_, 0} =
      System.cmd(
        "sh",
        [
          "-c",
          ~s(setsid sh -c 'echo $$ > "$1"; exec sleep 30' sh "$1" </dev/null >/dev/null 2>&1 &),
          "sh",
          pid_file
        ],
        env: [{ProcScan.var(), tag}]
      )

    child = pid!(pid_file)
    {dead, 0} = System.cmd("sh", ["-c", "echo $$"])

    :ok =
      StateStore.write(47, %{
        os_pid: String.to_integer(String.trim(dead)),
        pgid: String.to_integer(String.trim(dead)),
        proc_start: "Thu Jan  1 00:00:00 1970",
        started_at: DateTime.utc_now(),
        proc_tag: tag,
        proc_since: since,
        members: []
      })

    start_execution()
    refute alive?(child)
    refute File.exists?(Paths.record(47))
  end

  test "a reused group leader PID with another start time gets no signal", %{tmp_dir: dir} do
    {other, 0} = System.cmd("sh", ["-c", "setsid sleep 30 >/dev/null 2>&1 & echo $!"])
    File.write!(Path.join(dir, "other.pid"), other)
    other = String.to_integer(String.trim(other))
    tracking = %{tag: ProcScan.new_tag(48), since: ProcScan.now_ticks()}

    assert {:ok, %{continuous?: false, unknown?: true}} =
             ProcGroup.step(other, [{other, "Thu Jan  1 00:00:00 1970"}], 9, tracking)

    Process.sleep(50)
    assert alive?(other)
  end

  test "a member exiting while its environment is read counts as exited", %{pid_file: pid_file} do
    tag = ProcScan.new_tag(49)
    since = ProcScan.now_ticks()

    {_, 0} =
      System.cmd(
        "sh",
        [
          "-c",
          ~s(sh -c 'echo $$ > "$1"; exec sleep 30' sh "$1" </dev/null >/dev/null 2>&1 &),
          "sh",
          pid_file
        ],
        env: [{ProcScan.var(), tag}]
      )

    child = pid!(pid_file)
    environ = "/proc/#{child}/environ"
    tracking = %{tag: tag, since: since}

    gone =
      Map.put(tracking, :reader, &if(&1 == environ, do: {:error, :enoent}, else: File.read(&1)))

    assert {:ok, infos, _} = ProcScan.scan(tracking)
    assert Enum.any?(infos, &(&1.pid == child and &1.env == :tagged))
    assert {:ok, infos, _} = ProcScan.scan(gone)
    refute Enum.any?(infos, &(&1.pid == child))
    assert {:ok, %{empty?: true}} = ProcGroup.step(nil, [], nil, gone)
    assert {:ok, %{empty?: false}} = ProcGroup.step(nil, [], nil, tracking)

    denied =
      Map.put(tracking, :reader, &if(&1 == environ, do: {:error, :eacces}, else: File.read(&1)))

    assert {:ok, %{empty?: false, uncertain: [{^child, "sleep"}]}} =
             ProcGroup.step(nil, [], nil, denied)

    assert alive?(child)
  end

  test "classification of unreadable processes" do
    own = %{pid: 1, pgrp: 10, sid: 10}
    tracking = %{tag: "t", since: 100}
    info = &Map.merge(%{ppid: 1, pgrp: &1, sid: &1, start: 200, comm: "p", env: :unknown}, &2)

    member = info.(500, %{pid: 500, env: :tagged})
    child = info.(600, %{pid: 600, ppid: 500})
    session = info.(501, %{pid: 501, sid: 500})
    grandchild = info.(700, %{pid: 700, ppid: 600})
    older = info.(800, %{pid: 800, start: 50})
    daemon_session = info.(900, %{pid: 900, sid: 10})
    unrelated = info.(950, %{pid: 950})
    infos = [member, child, session, grandchild, older, daemon_session, unrelated]

    {members, uncertain} = ProcScan.classify(infos, tracking, own, [], MapSet.new())
    assert Enum.sort(Enum.map(members, & &1.pid)) == [500, 501, 600, 700]
    assert Enum.sort(Enum.map(uncertain, & &1.pid)) == [900, 950]

    # A verified member stays a member and links its session; the session of
    # a member that exited (or a reused PID) never links (code review 1 P1).
    {members, uncertain} =
      ProcScan.classify(
        [unrelated, info.(960, %{pid: 960, sid: 950}), info.(970, %{pid: 970, sid: 400})],
        tracking,
        own,
        [],
        MapSet.new([950])
      )

    assert Enum.sort(Enum.map(members, & &1.pid)) == [950, 960]
    assert Enum.map(uncertain, & &1.pid) == [970]

    # The CLI's group links while its continuity holds.
    {members, []} =
      ProcScan.classify([info.(980, %{pid: 980, pgrp: 77})], tracking, own, [77], MapSet.new())

    assert Enum.map(members, & &1.pid) == [980]
  end

  describe "a recorded PID reused by an unrelated process" do
    setup %{tmp_dir: dir} do
      %{stale: "Thu Jan  1 00:00:00 1970", dir: dir}
    end

    defp setsid_leader(dir, command) do
      file = Path.join(dir, "reused.pid")

      {_, 0} =
        System.cmd("sh", [
          "-c",
          ~s(setsid sh -c 'echo $$ > "$1"; #{command}' sh "$1" </dev/null >/dev/null 2>&1 &),
          "sh",
          file
        ])

      pid!(file)
    end

    test "is never signalled when its environment cannot be read (injected)", %{
      dir: dir,
      stale: stale
    } do
      other = setsid_leader(dir, "exec sleep 30")
      environ = "/proc/#{other}/environ"
      reader = &if(&1 == environ, do: {:error, :eacces}, else: File.read(&1))
      tracking = %{tag: ProcScan.new_tag(51), since: 0, reader: reader}

      assert {:ok, step} = ProcGroup.step(other, [{other, stale}], 9, tracking)
      refute step.continuous?
      assert {other, "sleep"} in step.uncertain
      Process.sleep(100)
      assert alive?(other)
    end

    test "is never signalled when it is really non-dumpable", %{dir: dir, stale: stale} do
      other = setsid_leader(dir, ~s(exec python3 "#{@helper}" "$1.nd"))
      eventually(fn -> File.exists?(Path.join(dir, "reused.pid.nd")) end, 1_000)
      assert {:error, :eacces} = File.read("/proc/#{other}/environ")
      tracking = %{tag: ProcScan.new_tag(52), since: 0}

      assert {:ok, step} = ProcGroup.step(other, [{other, stale}], 9, tracking)
      refute step.continuous?
      Process.sleep(100)
      assert alive?(other)
    end

    test "crash recovery leaves it running and keeps the record", %{dir: dir, stale: stale} do
      since = ProcScan.now_ticks()

      other = setsid_leader(dir, ~s(exec python3 "#{@helper}" "$1.nd"))
      eventually(fn -> File.exists?(Path.join(dir, "reused.pid.nd")) end, 1_000)

      :ok =
        StateStore.write(53, %{
          os_pid: other,
          pgid: other,
          proc_start: stale,
          started_at: DateTime.utc_now(),
          proc_tag: ProcScan.new_tag(53),
          proc_since: since,
          members: [%{pid: other, proc_start: stale}]
        })

      start_execution()
      Process.sleep(100)
      assert alive?(other)
      # As for a process group reused by an unrelated process: kept, not cleared.
      assert File.exists?(Paths.record(53))
    end
  end

  describe "without /proc" do
    setup do
      Application.put_env(:helmsman_daemon, :os_type, {:unix, :darwin})
      on_exit(fn -> Application.delete_env(:helmsman_daemon, :os_type) end)
    end

    test "a tracking adapter is unavailable and its runs fail closed", %{pid_file: pid_file} do
      assert [%{available: false, unavailable_reason: reason}] = Detector.scan([TrackingFake])
      assert reason =~ "Linux"
      start_execution()
      {_, _} = run(50, @success, pid_file)
      payload = finished(50)
      assert payload.status == :failed
      assert payload.failure_reason == :cli_error
      assert payload.error =~ "Linux"
      refute_received {:report, 50, %Report.Started{}, _, _, _}
    end
  end
end
