defmodule HelmsmanDaemon.Adapters.CursorRunWorkerTest do
  use HelmsmanDaemon.Case
  @moduletag :tmp_dir
  if :os.type() != {:unix, :linux}, do: @moduletag(:skip)
  alias HelmsmanDaemon.Adapters.CursorReplay
  alias HelmsmanDaemon.RunWorker
  @fixtures Path.expand("../../fixtures/cursor", __DIR__)

  setup do
    File.write!(Path.join(Paths.home(), "config.toml"), "[cursor]\nenabled = true\n")
    start_execution()
    :ok
  end

  defp start(id, scenario) do
    path = scenario!(Path.join(Paths.home(), "replay-#{id}"), scenario)
    run = spec(id)
    run = %{run | agent: %{run.agent | provider: :cursor, custom_args: [path]}}

    start_supervised!(
      {RunWorker, {run, [adapter: CursorReplay, reporter: TestReporter, kill_timeout_ms: 200]}}
    )
  end

  defp finished(id) do
    assert_receive {:report, ^id, %Report.Finished{} = payload, _, _, _}, 5_000
    payload
  end

  test "a recorded MCP tool run succeeds end to end" do
    start(1, CursorReplay.scenario(@fixtures, "mcp_tool_force"))
    payload = finished(1)
    assert payload.status == :succeeded
    assert payload.session_id == "4b42c4bb-7868-421b-9926-16e5d56f6d05"
    assert payload.summary == "helmsman-ok\nMANGO\nPINEAPPLE"
    # The private HOME goes with the run directory.
    eventually(fn -> File.ls(Paths.run(1)) == {:ok, ["raw.log"]} end)
  end

  test "a run the daemon stops is decided by the daemon's reason" do
    start(2, CursorReplay.scenario(@fixtures, "interrupted", "sleep 600\n"))
    assert_receive {:report, 2, %Report.Started{}, _, _, _}
    assert_receive {:report, 2, %Report.Events{}, _, _, _}, 2_000
    Runs.cancel(2)
    assert finished(2).status == :cancelled
  end

  test "a recorded authentication failure" do
    start(3, CursorReplay.scenario(@fixtures, "error_auth_nokey"))
    payload = finished(3)
    assert {payload.status, payload.failure_reason} == {:failed, :provider_auth}
  end
end
