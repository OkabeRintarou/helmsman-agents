defmodule HelmsmanDaemon.Adapters.CodexRunWorkerTest do
  use HelmsmanDaemon.Case
  @moduletag :tmp_dir
  alias HelmsmanDaemon.Adapters.{Codex, CodexReplay}
  alias HelmsmanDaemon.{CodexFixtures, RunWorker}

  setup do
    start_execution()
    :ok
  end

  for {name, status, reason} <- [
        {"success_mcp_tool", :succeeded, nil},
        {"success_big_output", :succeeded, nil},
        {"error_auth", :failed, :provider_auth}
      ] do
    test "RunWorker replays #{name} with complete frames", %{tmp_dir: dir} do
      name = unquote(name)
      path = scenario!(Path.join(dir, "replay"), CodexFixtures.scenario(name))
      run = spec(1, path)

      worker =
        start_supervised!({RunWorker, {run, [adapter: CodexReplay, reporter: TestReporter]}})

      monitor = Process.monitor(worker)
      {finished, events} = collect(run.run_id, [])
      assert finished.status == unquote(status)
      assert finished.failure_reason == unquote(reason)
      assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}, 3_000
      assert File.ls!(Paths.run(1)) == ["raw.log"]
      refute File.exists?(Paths.record(1))
      assert File.dir?(Path.join(dir, "codex"))
      {expected, _, state} = CodexFixtures.replay(name, run)

      assert Enum.map(Enum.reject(events, &(&1.type in [:status, :error])), & &1.type) ==
               Enum.map(Enum.reject(expected, &(elem(&1, 0) in [:status, :error])), &elem(&1, 0))

      assert finished.session_id == state.session_id
      assert finished.usage.input_tokens == state.usage.input_tokens

      if name == "success_big_output",
        do: assert(Enum.any?(events, &(&1.type == :tool_result and &1.data.truncated)))
    end
  end

  test "resumed Codex reports only the session confirmed by the CLI", %{tmp_dir: dir} do
    for {id, fixture, expected} <- [
          {32, "resume_missing", nil},
          {33, "resume_ok", "01a12e89-c855-72a1-bf5d-f11f2ab7e973"}
        ] do
      path = scenario!(Path.join(dir, "resume-#{id}"), CodexFixtures.scenario(fixture))
      run = %{spec(id, path) | resume_session_id: "candidate-session"}

      worker =
        start_supervised!({RunWorker, {run, [adapter: CodexReplay, reporter: TestReporter]}})

      assert_receive {:report, ^id, %Report.Started{session_id: nil}, _, _, _}, 2_000
      {finished, events} = collect(id, [])
      assert finished.session_id == expected

      if expected do
        assert finished.status == :succeeded
        assert Enum.any?(events, &(&1.type == :session and &1.data.session_id == expected))
      else
        assert finished.failure_reason == :cli_error
        refute Enum.any?(events, &(&1.type == :session))
      end

      eventually(fn -> not Process.alive?(worker) end)
      stop_supervised(RunWorker)
    end
  end

  test "Codex replay rejects 40 MiB JSON output without waiting for idle timeout", %{tmp_dir: dir} do
    path = scenario!(Path.join(dir, "oversize"), "json_line_bytes 41943040\nsleep 600\n")
    run = spec(1, path)
    run = %{run | limits: %{run.limits | timeout_ms: 60_000, idle_timeout_ms: 60_000}}

    worker =
      start_supervised!(
        {RunWorker, {run, [adapter: CodexReplay, reporter: TestReporter, kill_timeout_ms: 200]}}
      )

    monitor = Process.monitor(worker)
    {finished, _} = collect(1, [])
    assert finished.status == :failed
    assert finished.failure_reason == :cli_error
    assert finished.error =~ "32.0 MB"
    assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}, 2_000
  end

  test "project config rejects preparation before starting CLI", %{tmp_dir: dir} do
    work = Paths.private_dir!(Path.join([dir, "scratch", "bos", "BOS-1", ".codex"]))
    File.write!(Path.join(work, "config.toml"), "")
    run = spec(1, "unused")
    worker = start_supervised!({RunWorker, {run, [adapter: Codex, reporter: TestReporter]}})
    monitor = Process.monitor(worker)
    {finished, _} = collect(1, [])
    assert finished.failure_reason == :workspace_prepare
    assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}, 3_000
    refute File.exists?(Path.join(Paths.run(1), "raw.log"))
  end

  defp collect(id, events) do
    receive do
      {:report, ^id, %Report.Events{events: next}, _, _, _} -> collect(id, events ++ next)
      {:report, ^id, %Report.Finished{} = finished, _, _, _} -> {finished, events}
      {:report, ^id, _, _, _, _} -> collect(id, events)
    after
      8_000 -> flunk("Codex replay did not finish")
    end
  end
end
