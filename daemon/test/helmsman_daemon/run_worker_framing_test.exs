defmodule HelmsmanDaemon.RunWorkerFramingTest do
  use HelmsmanDaemon.Case
  @moduletag :tmp_dir
  alias HelmsmanDaemon.{LineBuffer, RunWorker}

  setup do
    start_execution()
    on_exit(fn -> Application.delete_env(:helmsman_daemon, :framing_limit) end)
    :ok
  end

  test "32 MiB chunks assemble linearly, exact boundary passes, oversize tails are discarded" do
    limit = 32 * 1_048_576
    chunk = String.duplicate("x", 4_096)

    {time, buffer} =
      :timer.tc(fn ->
        buffer =
          Enum.reduce(1..8_192, LineBuffer.new(), fn _, buffer ->
            assert {[], buffer} = LineBuffer.push(buffer, chunk, limit)
            buffer
          end)

        {buffer, LineBuffer.push(buffer, "\n", limit)}
      end)

    assert time < 2_000_000
    {buffer, {[line], _}} = buffer
    assert byte_size(line) == limit
    assert {[:overflow], dropping} = LineBuffer.push(buffer, "x", limit)
    assert {[], dropping} = LineBuffer.push(dropping, "discarded", limit)
    assert {["next", "last"], _} = LineBuffer.push(dropping, "tail\nnext\nlast\n", limit)
  end

  test "200 KiB in 50 writes arrives intact and raw log matches", %{tmp_dir: dir} do
    Application.put_env(:helmsman_daemon, :framing_limit, 256 * 1_024)

    cli =
      executable!(
        dir,
        "chunk-cli",
        "for i in $(seq 1 50); do head -c 4096 /dev/zero | tr '\\000' x; sleep 0.002; done\nprintf '\\n'\n"
      )

    run = framing_run(1, cli)
    {finished, worker} = execute(run)
    assert finished.status == :succeeded
    assert_receive {:framed, :stdout, 204_800, _}
    refute_receive {:framed, :stdout, _, _}, 20
    assert byte_size(File.read!(Path.join(Paths.run(1), "raw.log"))) == 204_801
    assert Process.alive?(worker) == false
  end

  test "over-limit output stops immediately, discards tail and kills process group", %{
    tmp_dir: dir
  } do
    Application.put_env(:helmsman_daemon, :framing_limit, 64 * 1_024)

    cli =
      executable!(
        dir,
        "oversize-cli",
        "trap '' TERM\nhead -c 100000 /dev/zero | tr '\\000' x\nprintf 'tail\\n'\nsleep 600 &\nwait\n"
      )

    run = framing_run(1, cli)
    started = System.monotonic_time(:millisecond)
    {finished, _worker} = execute(run)
    assert System.monotonic_time(:millisecond) - started < 2_000
    assert finished.status == :failed
    assert finished.failure_reason == :cli_error
    assert finished.error =~ "exceeded"
    refute_receive {:framed, :stdout, _, _}, 20
    refute File.exists?(Paths.record(1))
  end

  test "40 MiB Codex limit failure finishes within seconds", %{tmp_dir: dir} do
    cli =
      executable!(
        dir,
        "codex-oversize-cli",
        "head -c 41943040 /dev/zero | tr '\\000' x\nprintf '\\n'\nsleep 600\n"
      )

    {finished, _} = execute(framing_run(1, cli))
    assert finished.failure_reason == :cli_error
    assert finished.error =~ "32.0 MB"
    refute_receive {:framed, :stdout, _, _}, 20
  end

  test "stderr still splits at 1 MiB for bounded stdout adapters", %{tmp_dir: dir} do
    cli =
      executable!(
        dir,
        "stderr-cli",
        "head -c 1048577 /dev/zero | tr '\\000' x >&2\nprintf '\\n' >&2\n"
      )

    {finished, _} = execute(framing_run(1, cli))
    assert finished.status == :succeeded
    assert_receive {:framed, :stderr, 1_048_576, _}
    assert_receive {:framed, :stderr, 1, _}
  end

  test "existing cancel and timeout conclusions take priority over output overflow", %{
    tmp_dir: dir
  } do
    Application.put_env(:helmsman_daemon, :framing_limit, 64 * 1_024)

    cli =
      executable!(
        dir,
        "stopping-cli",
        "trap '' TERM\nsleep 0.1\nhead -c 100000 /dev/zero | tr '\\000' x\nsleep 600 &\nwait\n"
      )

    for reason <- [:cancel, :timeout] do
      run = framing_run(if(reason == :cancel, do: 1, else: 2), cli)
      Application.put_env(:helmsman_daemon, :framing_cli, cli)

      worker =
        start_supervised!(
          {RunWorker,
           {run,
            [
              adapter: HelmsmanDaemon.Adapters.FramingLauncher,
              reporter: TestReporter,
              kill_timeout_ms: 200
            ]}}
        )

      monitor = Process.monitor(worker)
      eventually(fn -> :sys.get_state(worker).phase == :running end)
      GenServer.cast(worker, {:stop, reason})
      finished = collect(run.run_id)
      assert finished.status == if(reason == :cancel, do: :cancelled, else: :failed)
      assert finished.failure_reason == if(reason == :cancel, do: nil, else: :timeout)
      assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}, 2_000
      stop_supervised(RunWorker)
    end

    Application.delete_env(:helmsman_daemon, :framing_cli)
  end

  defp framing_run(id, cli) do
    run = spec(id, cli)

    %{
      run
      | agent: %{run.agent | name: self() |> :erlang.pid_to_list() |> List.to_string()},
        limits: %{run.limits | idle_timeout_ms: 60_000, timeout_ms: 60_000}
    }
  end

  defp executable!(dir, name, body) do
    path = Path.join(dir, name)
    File.write!(path, "#!/bin/sh\n" <> body)
    File.chmod!(path, 0o700)
    path
  end

  defp execute(run) do
    # Fake adapter accepts a scenario; override its argv after prepare with a dedicated launcher.
    Application.put_env(:helmsman_daemon, :framing_cli, hd(run.agent.custom_args))
    on_exit(fn -> Application.delete_env(:helmsman_daemon, :framing_cli) end)

    worker =
      start_supervised!(
        {RunWorker,
         {run,
          [
            adapter: HelmsmanDaemon.Adapters.FramingLauncher,
            reporter: TestReporter,
            kill_timeout_ms: 200
          ]}}
      )

    monitor = Process.monitor(worker)
    finished = collect(run.run_id)
    assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}, 2_000
    {finished, worker}
  end

  defp collect(id) do
    receive do
      {:report, ^id, %Report.Finished{} = finished, _, _, _} -> finished
      {:report, ^id, _, _, _, _} -> collect(id)
    after
      4_000 -> flunk("bounded CLI did not finish")
    end
  end
end
