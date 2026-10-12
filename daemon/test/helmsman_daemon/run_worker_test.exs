defmodule HelmsmanDaemon.RunWorkerTest do
  use HelmsmanDaemon.Case
  @moduletag :tmp_dir
  defmodule StuckGroup do
    def snapshot(pgid), do: HelmsmanDaemon.ProcGroup.snapshot(pgid)

    def step(_pgid, members, _signal),
      do: {:ok, %{members: members, empty?: false, continuous?: true, unknown?: false}}
  end

  defmodule CrashingFinish do
    alias HelmsmanDaemon.Adapters.Fake
    defdelegate prepare(spec, run_dir, work_dir), to: Fake
    defdelegate init_state(spec), to: Fake
    defdelegate handle_output(stream, line, state), to: Fake
    defdelegate interrupt(state), to: Fake
    def finish(_status, _state), do: raise("adapter finalization failed")
  end

  defmodule CrashingFlush do
    alias HelmsmanDaemon.Adapters.Fake
    defdelegate prepare(spec, run_dir, work_dir), to: Fake
    defdelegate init_state(spec), to: Fake
    defdelegate finish(status, state), to: Fake
    defdelegate interrupt(state), to: Fake
    def handle_output(_stream, _line, _state), do: raise("adapter output failed")
  end

  setup do
    start_execution()
    :ok
  end

  test "success reports started then events then finished and cleans private files" do
    {:ok, worker} = Runs.start_run(spec(1), reporter: TestReporter)
    ref = Process.monitor(worker)
    assert_receive {:report, 1, %Report.Starting{}, _, _, _}
    assert_receive {:report, 1, %Report.Started{}, _, _, _}, 1_000
    assert_receive {:report, 1, %Report.Events{events: events}, _, _, _}, 2_000
    assert Enum.map(events, & &1.seq) == [1, 2]
    assert_receive {:report, 1, %Report.Finished{status: :succeeded}, _, _, _}, 2_000
    assert_receive {:DOWN, ^ref, _, _, :normal}
    assert File.ls!(Paths.run(1)) == ["raw.log"]
    refute File.exists?(Paths.record(1))
    assert Runs.free_slots() == 4
  end

  test "repo rejection never starts CLI" do
    {:ok, _} = Runs.start_run(%{spec(2) | repo: %{}}, reporter: TestReporter)

    assert_receive {:report, 2,
                    %Report.Finished{status: :failed, failure_reason: :workspace_prepare}, _, _,
                    _},
                   1_000

    refute_receive {:report, 2, %Report.Started{}, _, _, _}
  end

  test "abort cleans without starting or finishing" do
    TestReporter.configure(fn %Report.Starting{} ->
      {:ok, %Reply.Starting{action: :abort, reason: "obsolete"}}
    end)

    {:ok, worker} = Runs.start_run(spec(3), reporter: TestReporter)
    ref = Process.monitor(worker)
    assert_receive {:DOWN, ^ref, _, _, :normal}, 1_000
    refute File.exists?(Paths.record(3))
    refute_receive {:report, 3, %Report.Started{}, _, _, _}
    refute_receive {:report, 3, %Report.Finished{}, _, _, _}
  end

  test "environment reserves daemon variables and never exports daemon credential", %{
    tmp_dir: dir
  } do
    Credentials.write(credentials())

    path =
      scenario!(
        Path.join(dir, "env"),
        "dump_env\ndump_argv\njson {\"type\":\"result\",\"data\":{\"text\":\"done\",\"success\":true}}\n"
      )

    run = spec(4, path)
    run = %{run | agent: %{run.agent | env: %{"HELMSMAN_RUN_TOKEN" => "x", "FOO" => "1"}}}

    {:ok, _} =
      Runs.start_run(run, reporter: TestReporter, base_env: %{"PATH" => System.get_env("PATH")})

    assert_receive {:report, 4, %Report.Finished{status: :succeeded}, _, _, _}, 3_000
    raw = File.read!(Path.join(Paths.run(4), "raw.log"))
    assert raw =~ "HELMSMAN_RUN_TOKEN=hmr_run_token"
    assert raw =~ "FOO=1"
    assert raw =~ "TMPDIR=#{Paths.run(4)}/tmp"
    refute raw =~ credentials().token
    assert_receive {:report, 4, %Report.Events{events: events}, _, _, _}
    assert hd(events).type == :status
    assert hd(events).data.message =~ "HELMSMAN_RUN_TOKEN"
    refute hd(events).data.message =~ "=x"
  end

  test "task scratch directory persists across runs" do
    {:ok, _} = Runs.start_run(spec(5), reporter: TestReporter)
    assert_receive {:report, 5, %Report.Finished{}, _, _, _}, 3_000
    eventually(fn -> Runs.active() == [] end)
    path = Path.join([Paths.home(), "scratch", "bos", "BOS-1"])
    File.write!(Path.join(path, "notes.md"), "persist")
    {:ok, _} = Runs.start_run(spec(6), reporter: TestReporter)
    assert_receive {:report, 6, %Report.Finished{}, _, _, _}, 3_000
    assert File.read!(Path.join(path, "notes.md")) == "persist"
  end

  test "idle and total timeout override result" do
    for {id, key, reason} <- [{7, :idle_timeout_ms, :stalled}, {8, :timeout_ms, :timeout}] do
      run = spec(id, "stalled")
      run = %{run | limits: Map.put(run.limits, key, 300)}
      {:ok, _} = Runs.start_run(run, reporter: TestReporter, kill_timeout_ms: 200)

      assert_receive {:report, ^id, %Report.Finished{status: :failed, failure_reason: ^reason}, _,
                      _, _},
                     2_000

      eventually(fn -> Runs.active() == [] end)
    end
  end

  test "cancel escalates for ignored TERM and kills child", %{tmp_dir: dir} do
    pid_file = Path.join(dir, "child_pid")
    run = spec(9, "ignore_term")
    run = %{run | agent: %{run.agent | env: %{"FAKE_CLI_CHILD_PID_FILE" => pid_file}}}
    {:ok, worker} = Runs.start_run(run, reporter: TestReporter, kill_timeout_ms: 200)
    assert_receive {:report, 9, %Report.Started{}, _, _, _}, 1_000
    eventually(fn -> File.exists?(pid_file) end)
    child = File.read!(pid_file) |> String.trim() |> String.to_integer()
    Runs.cancel(9)
    assert_receive {:report, 9, %Report.Finished{status: :cancelled}, _, _, _}, 2_000
    eventually(fn -> not Process.alive?(worker) end)
    eventually(fn -> not alive?(child) end)
  end

  test "nonzero exit includes exit code and stderr", %{tmp_dir: dir} do
    path = scenario!(Path.join(dir, "bad"), "err bad failure\nexit 7\n")
    {:ok, _} = Runs.start_run(spec(10, path), reporter: TestReporter)

    assert_receive {:report, 10, %Report.Finished{failure_reason: :cli_error, error: error}, _, _,
                    _},
                   3_000

    assert error =~ "7"
    assert error =~ "bad failure"
  end

  test "wrong_state terminates and never reports finished" do
    TestReporter.configure(fn
      %Report.Events{} ->
        {:error, %HelmsmanProtocol.ErrorReply{reason: :wrong_state, message: "late"}}

      payload ->
        TestReporter.default(payload)
    end)

    {:ok, worker} =
      Runs.start_run(spec(11, "stalled"), reporter: TestReporter, kill_timeout_ms: 200)

    ref = Process.monitor(worker)
    assert_receive {:DOWN, ^ref, _, _, :normal}, 2_000
    refute_receive {:report, 11, %Report.Finished{}, _, _, _}
  end

  test "invalid events and invalid finished both release slot without retry" do
    TestReporter.configure(fn
      %Report.Events{} -> {:reject, "bad event"}
      %Report.Finished{} -> {:reject, "bad finish"}
      payload -> TestReporter.default(payload)
    end)

    {:ok, worker} =
      Runs.start_run(spec(12, "stalled"), reporter: TestReporter, kill_timeout_ms: 200)

    ref = Process.monitor(worker)
    assert_receive {:report, 12, %Report.Events{}, _, _, _}, 1_000

    assert_receive {:report, 12,
                    %Report.Finished{status: :failed, failure_reason: :unknown, error: error}, _,
                    _, _},
                   2_000

    assert error =~ "bad event"
    assert_receive {:DOWN, ^ref, _, _, :normal}
    assert Runs.free_slots() == 4
    refute File.exists?(Paths.record(12))
    refute_receive {:report, 12, %Report.Events{}, _, _, _}
  end

  test "close_stdin output action lets echo CLI exit" do
    run = %{spec(13, "echo") | prompt: "close_stdin"}
    {:ok, _} = Runs.start_run(run, reporter: TestReporter)
    assert_receive {:report, 13, %Report.Finished{status: :succeeded}, _, _, _}, 3_000
  end

  test "450 events batch at most 200 once per second and wait for confirmation", %{tmp_dir: dir} do
    lines =
      Enum.map_join(1..450, "\n", fn n ->
        "json " <> Jason.encode!(%{type: "text", data: %{text: to_string(n)}})
      end)

    path =
      scenario!(
        Path.join(dir, "batch"),
        lines <> "\njson {\"type\":\"result\",\"data\":{\"text\":\"done\",\"success\":true}}\n"
      )

    TestReporter.configure(fn
      %Report.Events{} -> :hold
      payload -> TestReporter.default(payload)
    end)

    {:ok, _} = Runs.start_run(spec(14, path), reporter: TestReporter)

    batches =
      for _ <- 1..3 do
        assert_receive {:report, 14, %Report.Events{events: events}, caller, ref, at}, 2_000
        assert length(events) <= 200
        refute_receive {:report, 14, %Report.Finished{}, _, _, _}, 30

        send(
          caller,
          {:report_result, ref, {:ok, %Reply.Events{acked_seq: List.last(events).seq}}}
        )

        {events, at}
      end

    assert batches |> Enum.flat_map(fn {events, _} -> Enum.map(events, & &1.seq) end) ==
             Enum.to_list(1..451)

    times = Enum.map(batches, &elem(&1, 1))
    assert Enum.at(times, 1) - hd(times) >= 1_000
    assert Enum.at(times, 2) - Enum.at(times, 1) >= 1_000
    assert_receive {:report, 14, %Report.Finished{status: :succeeded}, _, _, _}, 1_000
  end

  test "taskless run uses private scratch and removes it", %{tmp_dir: dir} do
    path =
      scenario!(
        Path.join(dir, "pwd"),
        "out private scratch\njson {\"type\":\"result\",\"data\":{\"text\":\"done\",\"success\":true}}\n"
      )

    run = %{spec(15, path) | task: nil}

    TestReporter.configure(fn
      %Report.Starting{} -> :hold
      payload -> TestReporter.default(payload)
    end)

    {:ok, worker} = Runs.start_run(run, reporter: TestReporter)
    assert_receive {:report, 15, %Report.Starting{}, ^worker, ref, _}, 1_000
    assert File.dir?(Path.join(Paths.run(15), "scratch"))
    assert Bitwise.band(File.stat!(Path.join(Paths.run(15), "scratch")).mode, 0o777) == 0o700
    send(worker, {:report_result, ref, {:ok, %Reply.Starting{action: :proceed, reason: nil}}})
    assert_receive {:report, 15, %Report.Finished{status: :succeeded}, _, _, _}, 2_000
    eventually(fn -> not Process.alive?(worker) end)
    refute File.exists?(Path.join(Paths.run(15), "scratch"))
  end

  test "continuous fragments without newline keep run alive and exit flush adds no idle timer", %{
    tmp_dir: dir
  } do
    script = Path.join(dir, "fragment-cli")

    File.write!(
      script,
      "#!/bin/sh\nif [ \"$1\" = --version ]; then echo 1.0.0; exit; fi\nread input\nwhile IFS= read -r fragment; do printf x; done\n"
    )

    File.chmod!(script, 0o700)
    old = System.get_env("HELMSMAN_FAKE_CLI")
    System.put_env("HELMSMAN_FAKE_CLI", script)

    on_exit(fn ->
      if old,
        do: System.put_env("HELMSMAN_FAKE_CLI", old),
        else: System.delete_env("HELMSMAN_FAKE_CLI")
    end)

    run = spec(20, "echo")
    run = %{run | limits: %{run.limits | idle_timeout_ms: 60_000}}

    TestReporter.configure(fn
      %Report.Finished{} -> :hold
      payload -> TestReporter.default(payload)
    end)

    {:ok, worker} = Runs.start_run(run, reporter: TestReporter)
    assert_receive {:report, 20, %Report.Started{}, _, _, _}, 1_000
    pgid = :sys.get_state(worker).pgid

    for n <- 1..10 do
      :ok = :sys.suspend(worker)

      try do
        idle_timer = :sys.get_state(worker).idle_timer
        Process.cancel_timer(idle_timer)
        # Reproduce the review's scheduling delay after cancelling the real timer.
        Process.sleep(170)
        :ok = :exec.send(pgid, "fragment\n")

        # Establish real stdout before explicitly delivering the expired reference.
        eventually(fn ->
          {:messages, messages} = Process.info(worker, :messages)
          Enum.any?(messages, &match?({:stdout, ^pgid, "x"}, &1))
        end)

        send(worker, {:timeout, idle_timer, :idle_timeout})
        {:messages, messages} = Process.info(worker, :messages)
        stdout_index = Enum.find_index(messages, &match?({:stdout, ^pgid, "x"}, &1))
        timeout_index = Enum.find_index(messages, &(&1 == {:timeout, idle_timer, :idle_timeout}))
        assert is_integer(stdout_index)
        assert is_integer(timeout_index)
        assert stdout_index < timeout_index
      after
        :sys.resume(worker)
      end

      eventually(fn -> :sys.get_state(worker).streams.stdout == String.duplicate("x", n) end)
      assert :sys.get_state(worker).stop_reason == nil
    end

    :ok = :exec.send(pgid, :eof)
    assert_receive {:report, 20, %Report.Events{events: events}, _, _, _}, 2_000
    assert Enum.any?(events, &(&1.type == :text and &1.data.text == "xxxxxxxxxx"))
    assert_receive {:report, 20, %Report.Finished{failure_reason: reason}, ^worker, ref, _}, 2_000
    refute reason == :stalled
    assert :sys.get_state(worker).idle_timer == nil
    Process.sleep(200)
    assert Process.alive?(worker)
    send(worker, {:report_result, ref, {:ok, %Reply.Empty{}}})
    eventually(fn -> not Process.alive?(worker) end)
  end

  test "leader exits on TERM while child ignores TERM; slot remains until child KILL", %{
    tmp_dir: dir
  } do
    script = Path.join(dir, "leader-cli")
    child_file = Path.join(dir, "child-leader")

    File.write!(
      script,
      "#!/bin/sh\nsh -c 'trap \"\" TERM; echo $$ > \"$FAKE_CLI_CHILD_PID_FILE\"; exec sleep 600' &\nwait\n"
    )

    File.chmod!(script, 0o700)
    old = System.get_env("HELMSMAN_FAKE_CLI")
    System.put_env("HELMSMAN_FAKE_CLI", script)

    on_exit(fn ->
      if old,
        do: System.put_env("HELMSMAN_FAKE_CLI", old),
        else: System.delete_env("HELMSMAN_FAKE_CLI")
    end)

    run = spec(21)
    run = %{run | agent: %{run.agent | env: %{"FAKE_CLI_CHILD_PID_FILE" => child_file}}}
    {:ok, worker} = Runs.start_run(run, reporter: TestReporter, kill_timeout_ms: 200)
    assert_receive {:report, 21, %Report.Started{}, _, _, _}, 1_000
    eventually(fn -> File.exists?(child_file) end)
    child = File.read!(child_file) |> String.trim() |> String.to_integer()
    {:ok, record} = HelmsmanDaemon.StateStore.read(21)
    leader = record["os_pid"]
    Runs.cancel(21)
    eventually(fn -> not alive?(leader) end)
    assert alive?(child)
    assert Runs.free_slots() == 3
    assert File.exists?(Paths.record(21))
    assert_receive {:report, 21, %Report.Finished{status: :cancelled}, _, _, _}, 2_000
    eventually(fn -> not Process.alive?(worker) and not alive?(child) end)
    assert Runs.free_slots() == 4
    refute File.exists?(Paths.record(21))
  end

  test "natural CLI exit cleans a TERM-ignoring background child before finished", %{tmp_dir: dir} do
    script = Path.join(dir, "natural-cli")
    child_file = Path.join(dir, "natural-child")

    File.write!(
      script,
      "#!/bin/sh\nsh -c 'trap \"\" TERM; echo $$ > \"$FAKE_CLI_CHILD_PID_FILE\"; exec sleep 600' &\nwhile [ ! -s \"$FAKE_CLI_CHILD_PID_FILE\" ]; do sleep 0.01; done\nexit 0\n"
    )

    File.chmod!(script, 0o700)
    old = System.get_env("HELMSMAN_FAKE_CLI")
    System.put_env("HELMSMAN_FAKE_CLI", script)

    on_exit(fn ->
      if old,
        do: System.put_env("HELMSMAN_FAKE_CLI", old),
        else: System.delete_env("HELMSMAN_FAKE_CLI")
    end)

    run = spec(22)
    run = %{run | agent: %{run.agent | env: %{"FAKE_CLI_CHILD_PID_FILE" => child_file}}}
    {:ok, worker} = Runs.start_run(run, reporter: TestReporter, kill_timeout_ms: 200)
    eventually(fn -> File.exists?(child_file) end)
    child = File.read!(child_file) |> String.trim() |> String.to_integer()
    assert_receive {:report, 22, %Report.Finished{}, _, _, _}, 2_000
    refute alive?(child)
    eventually(fn -> not Process.alive?(worker) end)
    refute File.exists?(Paths.record(22))
  end

  test "cleanup deadline releases slot and preserves unresolved state with error" do
    {:ok, worker} =
      Runs.start_run(spec(23),
        reporter: TestReporter,
        proc_group: StuckGroup,
        kill_timeout_ms: 50,
        group_cleanup_timeout_ms: 50
      )

    assert_receive {:report, 23, %Report.Finished{error: error}, _, _, _}, 2_000
    assert error =~ "process group cleanup timed out"
    eventually(fn -> not Process.alive?(worker) end)
    assert Runs.free_slots() == 4
    assert File.exists?(Paths.record(23))
  end

  test "trusted DOWN snapshot survives finish and residual-output callback crashes", %{
    tmp_dir: dir
  } do
    for {id, adapter} <- [{24, CrashingFinish}, {25, CrashingFlush}] do
      script = Path.join(dir, "callback-cli-#{id}")
      child_file = Path.join(dir, "callback-child-#{id}")

      File.write!(
        script,
        "#!/bin/sh\nread input\nsh -c 'trap \"\" TERM; echo $$ > \"$FAKE_CLI_CHILD_PID_FILE\"; exec sleep 600' &\nwhile [ ! -s \"$FAKE_CLI_CHILD_PID_FILE\" ]; do sleep 0.01; done\nprintf partial\nsleep 0.15\nexit 0\n"
      )

      File.chmod!(script, 0o700)
      old = System.get_env("HELMSMAN_FAKE_CLI")
      System.put_env("HELMSMAN_FAKE_CLI", script)
      run = spec(id)
      run = %{run | agent: %{run.agent | env: %{"FAKE_CLI_CHILD_PID_FILE" => child_file}}}
      {:ok, worker} = Runs.start_run(run, reporter: TestReporter, adapter: adapter)
      assert_receive {:report, ^id, %Report.Started{}, _, _, _}, 1_000
      eventually(fn -> File.exists?(child_file) end)
      child = File.read!(child_file) |> String.trim() |> String.to_integer()

      assert_receive {:report, ^id, %Report.Finished{status: :failed, failure_reason: :unknown},
                      _, _, _},
                     3_000

      eventually(fn -> not Process.alive?(worker) and not alive?(child) end)
      assert Runs.free_slots() == 4
      refute File.exists?(Paths.record(id))
      assert File.ls!(Paths.run(id)) == ["raw.log"]
      refute_receive {:report, ^id, %Report.Started{}, _, _, _}

      if old,
        do: System.put_env("HELMSMAN_FAKE_CLI", old),
        else: System.delete_env("HELMSMAN_FAKE_CLI")
    end
  end
end
