defmodule HelmsmanDaemon.ClaudeSmokeTest do
  use HelmsmanDaemon.Case
  @moduletag :real_cli
  @moduletag :tmp_dir
  @moduletag timeout: 240_000
  alias HelmsmanDaemon.Adapters.Claude
  alias HelmsmanDaemon.RunWorker

  setup do
    start_execution()
    :ok
  end

  test "real Claude succeeds, resumes the same task and optionally calls MCP" do
    assert {:ok, _} = Claude.detect()
    run = spec(10)

    run = %{
      run
      | prompt: "Reply with exactly OK",
        agent: %{run.agent | custom_args: []},
        limits: %{run.limits | timeout_ms: 120_000, idle_timeout_ms: 120_000}
    }

    {first, _} = execute(run)
    assert first.status == :succeeded
    assert is_binary(first.session_id) and first.session_id != ""
    assert first.summary =~ "OK"

    {second, _} =
      execute(%{
        run
        | run_id: 11,
          resume_session_id: first.session_id,
          prompt: "What did you reply last time?"
      })

    assert second.status == :succeeded
    assert second.session_id == first.session_id
    assert second.summary =~ "OK"

    if System.get_env("HELMSMAN_REAL_MCP_URL") && System.get_env("HELMSMAN_REAL_MCP_TOKEN") do
      url = System.fetch_env!("HELMSMAN_REAL_MCP_URL")
      token = System.fetch_env!("HELMSMAN_REAL_MCP_TOKEN")

      {third, events} =
        execute(%{
          run
          | run_id: 12,
            mcp: %{run.mcp | url: url, token: token},
            prompt: "Call mcp__helmsman__whoami. Reply OK."
        })

      assert third.status == :succeeded

      assert Enum.any?(
               events,
               &(&1.type == :tool_call and &1.data.name == "mcp__helmsman__whoami")
             )
    end
  end

  defp execute(run) do
    worker = start_supervised!({RunWorker, {run, [adapter: Claude, reporter: TestReporter]}})
    monitor = Process.monitor(worker)
    {finished, events} = collect(run.run_id, [])
    assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}, 15_000
    assert File.ls!(Paths.run(run.run_id)) == ["raw.log"]
    refute File.exists?(Paths.record(run.run_id))
    stop_supervised(RunWorker)
    {finished, events}
  end

  defp collect(id, events) do
    receive do
      {:report, ^id, %Report.Events{events: next}, _, _, _} -> collect(id, events ++ next)
      {:report, ^id, %Report.Finished{} = finished, _, _, _} -> {finished, events}
      {:report, ^id, _, _, _, _} -> collect(id, events)
    after
      120_000 -> flunk("real Claude did not finish")
    end
  end
end
