defmodule HelmsmanDaemon.CodexSmokeTest do
  use HelmsmanDaemon.Case
  @moduletag :real_cli
  @moduletag :tmp_dir
  @moduletag timeout: 300_000
  alias HelmsmanDaemon.Adapters.Codex
  alias HelmsmanDaemon.RunWorker

  setup do
    home = Path.expand(System.get_env("HELMSMAN_REAL_HOME", "~/.helmsman-dev"))
    System.put_env("HELMSMAN_HOME", home)
    Paths.ensure!()
    start_execution()
    :ok
  end

  test "real Codex succeeds, resumes, optionally calls MCP and stops without group remnants" do
    assert {:ok, _} = Codex.detect()
    run = spec(10)

    run = %{
      run
      | prompt: "Reply with exactly OK",
        agent: %{
          run.agent
          | provider: :codex,
            model: System.get_env("HELMSMAN_REAL_MODEL", "gpt-6-luna"),
            effort: "low",
            custom_args: []
        },
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
      {third, events} =
        execute(%{
          run
          | run_id: 12,
            mcp: %{
              run.mcp
              | url: System.fetch_env!("HELMSMAN_REAL_MCP_URL"),
                token: System.fetch_env!("HELMSMAN_REAL_MCP_TOKEN")
            },
            prompt: "Call helmsman whoami. Reply OK."
        })

      assert third.status == :succeeded

      assert Enum.any?(
               events,
               &(&1.type == :tool_call and &1.data.name == "mcp__helmsman__whoami")
             )
    end

    {cancelled, _} = execute(%{run | run_id: 13, prompt: "Run sleep 30, then reply DONE."}, true)
    assert cancelled.status == :cancelled
  end

  defp execute(run, stop? \\ false) do
    worker = start_supervised!({RunWorker, {run, [adapter: Codex, reporter: TestReporter]}})
    monitor = Process.monitor(worker)

    eventually(fn -> is_integer(:sys.get_state(worker).pgid) end)
    pgid = :sys.get_state(worker).pgid

    if stop? do
      Process.sleep(3_000)
      GenServer.cast(worker, {:stop, :cancel})
    end

    {finished, events} = collect(run.run_id, [], if(stop?, do: 10_000, else: 120_000))
    assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}, 1_000
    assert File.ls!(Paths.run(run.run_id)) == ["raw.log"]
    refute File.exists?(Paths.record(run.run_id))
    {_, status} = System.cmd("kill", ["-0", "--", "-#{pgid}"], stderr_to_stdout: true)
    assert status != 0
    stop_supervised(RunWorker)
    {finished, events}
  end

  defp collect(id, events, timeout) do
    receive do
      {:report, ^id, %Report.Events{events: next}, _, _, _} ->
        collect(id, events ++ next, timeout)

      {:report, ^id, %Report.Finished{} = finished, _, _, _} ->
        {finished, events}

      {:report, ^id, _, _, _, _} ->
        collect(id, events, timeout)
    after
      timeout -> flunk("real Codex did not finish")
    end
  end
end
