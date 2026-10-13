defmodule HelmsmanDaemon.RunWorkerCopilotTest do
  use HelmsmanDaemon.Case
  @moduletag :tmp_dir
  alias HelmsmanDaemon.Adapters.CopilotReplay
  alias HelmsmanDaemon.RunWorker
  @fixtures Path.expand("../fixtures/copilot", __DIR__)
  setup do
    start_execution()
    :ok
  end

  test "inline hooks fail before the fake CLI or hook can write a marker", %{tmp_dir: dir} do
    hook_marker = Path.join(dir, "hook-marker")
    cli_marker = Path.join(dir, "cli-marker")
    cli = Path.join(dir, "marker-cli")
    File.write!(cli, "#!/bin/sh\nprintf started > #{cli_marker}\nexit 0\n")
    File.chmod!(cli, 0o700)
    previous = Application.get_env(:helmsman_daemon, :copilot_executable)
    Application.put_env(:helmsman_daemon, :copilot_executable, cli)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:helmsman_daemon, :copilot_executable, previous),
        else: Application.delete_env(:helmsman_daemon, :copilot_executable)
    end)

    hooks = %{"sessionStart" => [%{"type" => "command", "bash" => "touch #{hook_marker}"}]}

    File.write!(
      Path.join(Paths.copilot_home(), "settings.json"),
      JSON.encode!(%{"hooks" => hooks})
    )

    run = spec(4)
    run = %{run | agent: %{run.agent | provider: :copilot, custom_args: []}}

    worker =
      start_supervised!(
        {RunWorker, {run, [adapter: HelmsmanDaemon.Adapters.Copilot, reporter: TestReporter]}}
      )

    ref = Process.monitor(worker)
    {finished, events} = collect(4, [])
    assert finished.status == :failed
    assert finished.failure_reason == :cli_error
    assert finished.error =~ "settings.json: hooks"
    refute finished.error =~ hook_marker
    assert events == []
    assert_receive {:DOWN, ^ref, :process, ^worker, :normal}, 3000
    refute_receive {:report, 4, %Report.Started{}, _, _, _}
    refute File.exists?(cli_marker)
    refute File.exists?(hook_marker)
  end

  for {name, status, reason} <- [
        {"c3_mcp_toolcall", :succeeded, nil},
        {"c8_interrupt_sigterm", :failed, :cli_error}
      ] do
    test "RunWorker replays #{name}, reports and removes private files", %{tmp_dir: dir} do
      name = unquote(name)
      lines = File.read!(Path.join(@fixtures, name <> ".jsonl")) |> String.split("\n", trim: true)
      scenario = Enum.map_join(lines, "", &("json " <> &1 <> "\n")) <> "await_stdin_eof\nexit 0\n"
      run = spec(1, scenario!(Path.join(dir, "scenario"), scenario))

      worker =
        start_supervised!({RunWorker, {run, [adapter: CopilotReplay, reporter: TestReporter]}})

      ref = Process.monitor(worker)
      {finished, events} = collect(1, [])
      assert finished.status == unquote(status)
      assert finished.failure_reason == unquote(reason)
      assert_receive {:DOWN, ^ref, :process, ^worker, :normal}, 3000
      assert File.ls!(Paths.run(1)) == ["raw.log"]
      assert finished.session_id != nil

      if unquote(status) == :succeeded do
        assert Enum.any?(events, &(&1.type == :tool_call and &1.data.name == "helmsman-whoami"))
        assert Enum.any?(events, &(&1.type == :tool_result and &1.data.output == "helmsman-ok"))
        assert finished.usage.reasoning_tokens == 320
      end
    end
  end

  test "actual exec environment deletes outer variables and keeps tokens/provider", %{
    tmp_dir: dir
  } do
    scenario = "dump_env\njson {\"type\":\"result\",\"exitCode\":0}\nexit 0\n"
    run = spec(2, scenario!(Path.join(dir, "env-scenario"), scenario))

    run = %{
      run
      | agent: %{run.agent | env: %{"COPILOT_MODEL" => "bad", "COPILOT_ALLOW_ALL" => "true"}}
    }

    base =
      Map.merge(Map.take(System.get_env(), ["PATH", "HOME"]), %{
        "COPILOT_HOME" => "outer",
        "COPILOT_AGENT_SESSION_ID" => "outer",
        "COPILOT_ALLOW_ALL" => "true",
        "COPILOT_GITHUB_TOKEN" => "dummy-token",
        "COPILOT_PROVIDER_BASE_URL" => "dummy-provider"
      })

    worker =
      start_supervised!(
        {RunWorker, {run, [adapter: CopilotReplay, reporter: TestReporter, base_env: base]}}
      )

    ref = Process.monitor(worker)
    {finished, events} = collect(2, [])
    assert finished.status == :succeeded
    assert_receive {:DOWN, ^ref, :process, ^worker, :normal}, 3000
    log = File.read!(Path.join(Paths.run(2), "raw.log"))
    assert log =~ "COPILOT_HOME=#{Paths.copilot_home()}"
    assert log =~ "COPILOT_GITHUB_TOKEN=dummy-token"
    assert log =~ "COPILOT_PROVIDER_BASE_URL=dummy-provider"
    refute log =~ "COPILOT_HOME=outer"
    refute log =~ "COPILOT_ALLOW_ALL="
    refute log =~ "COPILOT_AGENT_SESSION_ID="
    refute log =~ "COPILOT_MODEL="

    for name <- ~w(COPILOT_ALLOW_ALL COPILOT_MODEL),
        do:
          assert(
            Enum.any?(events, &(&1.type == :status and String.contains?(&1.data.message, name)))
          )
  end

  test "daemon timeout takes precedence over interrupted fixture", %{tmp_dir: dir} do
    run =
      spec(
        3,
        scenario!(Path.join(dir, "stopped"), "json {\"type\":\"abort\",\"data\":{}}\nsleep 30\n")
      )

    run = %{run | limits: %{run.limits | timeout_ms: 100}}
    start_supervised!({RunWorker, {run, [adapter: CopilotReplay, reporter: TestReporter]}})
    {finished, _} = collect(3, [])
    assert finished.status == :failed and finished.failure_reason == :timeout
  end

  defp collect(id, events) do
    receive do
      {:report, ^id, %Report.Events{events: next}, _, _, _} -> collect(id, events ++ next)
      {:report, ^id, %Report.Finished{} = finished, _, _, _} -> {finished, events}
      {:report, ^id, _, _, _, _} -> collect(id, events)
    after
      5000 -> flunk("Copilot replay did not finish")
    end
  end
end
