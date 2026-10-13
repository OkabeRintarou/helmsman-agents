defmodule HelmsmanDaemon.Adapters.CopilotRealTest do
  use ExUnit.Case
  @moduletag :real_cli
  @moduletag :tmp_dir
  alias HelmsmanDaemon.Adapters.Copilot
  alias HelmsmanDaemon.{Paths, ProcGroup, RunWorker, TestReporter}
  alias HelmsmanProtocol.Report

  setup %{tmp_dir: home} do
    previous = System.get_env("HELMSMAN_HOME")
    System.put_env("HELMSMAN_HOME", home)

    on_exit(fn ->
      if previous,
        do: System.put_env("HELMSMAN_HOME", previous),
        else: System.delete_env("HELMSMAN_HOME")
    end)

    Paths.ensure!()
    HelmsmanDaemon.Case.start_execution()
    :ok
  end

  @tag timeout: 300_000
  test "new session, resume, RunWorker stop and resume", %{tmp_dir: home} do
    assert {:ok, %{models: models, version: version}} = Copilot.detect()
    assert "gpt-5-mini" in models
    first = run_spec(101, "Reply exactly COPILOT_OK. Do not use tools.")
    {finished, _events, _pid} = execute(first)
    assert finished.status == :succeeded, inspect(finished)
    assert finished.summary =~ "COPILOT_OK"
    assert is_binary(finished.session_id)

    resumed = %{
      run_spec(102, "Reply exactly RESUMED_OK. Do not use tools.")
      | resume_session_id: finished.session_id
    }

    {again, _events, _pid} = execute(resumed)
    assert again.status == :succeeded, inspect(again)
    assert again.session_id == finished.session_id

    stopping = %{
      run_spec(
        103,
        "Use the bash tool to run sleep 30 synchronously (initial_wait 40). Then reply SLEPT."
      )
      | resume_session_id: finished.session_id
    }

    {cancelled, events, pid} = execute(stopping, true)
    assert cancelled.status == :cancelled
    assert cancelled.session_id == finished.session_id
    assert {:ok, []} = ProcGroup.live_snapshot(pid)
    raw = File.read!(Path.join(Paths.run(103), "raw.log"))

    restored = %{
      run_spec(
        104,
        "Reply exactly RESTORED_OK. Do not use tools or continue any earlier command."
      )
      | resume_session_id: finished.session_id
    }

    {last, _, _} = execute(restored)
    assert last.status == :succeeded, inspect(last)
    assert last.summary =~ "RESTORED_OK"
    assert last.session_id == finished.session_id
    for id <- 101..104, do: assert(File.ls!(Paths.run(id)) == ["raw.log"])
    generated_keys = generated_configuration_keys()

    if path = System.get_env("HM_COPILOT_REAL_SUMMARY") do
      summary = %{
        new: finished.status,
        resume: again.status,
        stopped: cancelled.status,
        restored: last.status,
        stopped_pid: pid,
        no_live_group_members: true,
        events: Enum.map(events, & &1.type),
        native_abort_observed: String.contains?(raw, ~s("type":"abort")),
        native_result_observed: String.contains?(raw, ~s("type":"result")),
        session_id: finished.session_id,
        private_home_persistent: File.dir?(Path.join(home, "copilot-home")),
        cli_version: version,
        generated_configuration_keys: generated_keys
      }

      File.write!(path, JSON.encode!(summary))
    end
  end

  defp generated_configuration_keys do
    Map.new(~w(config.json settings.json), fn name ->
      keys =
        case File.read(Path.join(Paths.copilot_home(), name)) do
          {:ok, text} ->
            text
            |> String.split("\n")
            |> Enum.reject(&String.starts_with?(String.trim_leading(&1), "//"))
            |> Enum.join("\n")
            |> JSON.decode!()
            |> Map.keys()
            |> Enum.sort()

          {:error, :enoent} ->
            []
        end

      assert keys -- ["firstLaunchAt"] == [], "new CLI-generated keys: #{Enum.join(keys, ", ")}"
      {name, keys}
    end)
  end

  defp run_spec(id, prompt) do
    run = HelmsmanDaemon.Case.spec(id)

    %{
      run
      | prompt: prompt,
        agent: %{run.agent | provider: :copilot, model: "gpt-5-mini", custom_args: []},
        limits: %{run.limits | timeout_ms: 120_000, idle_timeout_ms: 120_000}
    }
  end

  defp execute(spec, stop? \\ false) do
    {:ok, worker} = RunWorker.start_link({spec, [adapter: Copilot, reporter: TestReporter]})
    monitor = Process.monitor(worker)
    collect(spec.run_id, worker, monitor, [], nil, stop?)
  end

  defp collect(id, worker, monitor, events, pid, stop?) do
    receive do
      {:report, ^id, %Report.Started{}, _, _, _} ->
        pid = :sys.get_state(worker).pgid
        collect(id, worker, monitor, events, pid, stop?)

      {:report, ^id, %Report.Events{events: next}, _, _, _} ->
        stop_now? = stop? and Enum.any?(next, &(&1.type == :tool_call and &1.data.name == "bash"))
        if stop_now?, do: GenServer.cast(worker, {:stop, :cancel})
        collect(id, worker, monitor, events ++ next, pid, stop? and not stop_now?)

      {:report, ^id, %Report.Finished{} = finished, _, _, _} ->
        assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}, 15_000
        {finished, events, pid}

      {:report, ^id, _, _, _, _} ->
        collect(id, worker, monitor, events, pid, stop?)
    after
      130_000 ->
        GenServer.cast(worker, {:stop, :timeout})
        flunk("real Copilot run did not finish")
    end
  end
end
