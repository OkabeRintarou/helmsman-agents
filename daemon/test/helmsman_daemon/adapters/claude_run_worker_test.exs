defmodule HelmsmanDaemon.Adapters.ClaudeRunWorkerTest do
  use HelmsmanDaemon.Case
  @moduletag :tmp_dir
  alias HelmsmanDaemon.Adapters.{Claude, ClaudeReplay}
  alias HelmsmanDaemon.RunWorker
  @fixtures Path.expand("../../fixtures/claude", __DIR__)

  setup do
    start_execution()
    :ok
  end

  for {name, status, reason} <- [
        {"success_mcp_tool", :succeeded, nil},
        {"error_auth", :failed, :provider_auth}
      ] do
    test "RunWorker normalizes #{name} and closes stdin before completion", %{tmp_dir: dir} do
      name = unquote(name)
      read = fn ext -> File.read!(Path.join(@fixtures, name <> ext)) end
      code = String.trim(read.(".exit"))

      scenario =
        Enum.map_join(
          String.split(read.(".stderr"), "\n", trim: true),
          "",
          &("err " <> &1 <> "\n")
        ) <>
          Enum.map_join(
            String.split(read.(".jsonl"), "\n", trim: true),
            "",
            &("json " <> &1 <> "\n")
          ) <>
          "await_stdin_eof\nexit #{code}\n"

      path = scenario!(Path.join(dir, "replay"), scenario)
      run = spec(1, path)

      worker =
        start_supervised!({RunWorker, {run, [adapter: ClaudeReplay, reporter: TestReporter]}})

      monitor = Process.monitor(worker)
      {finished, events} = collect(run.run_id, [])
      assert finished.status == unquote(status)
      assert finished.failure_reason == unquote(reason)
      assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}, 3_000
      assert File.ls!(Paths.run(1)) == ["raw.log"]
      refute File.exists?(Paths.record(1))
      assert Enum.map(events, & &1.seq) == Enum.to_list(1..length(events))

      {expected, _, state} =
        Enum.reduce(
          String.split(read.(".jsonl"), "\n", trim: true),
          {[], [], Claude.init_state(run)},
          fn line, {events, actions, state} ->
            {next, more, state} = Claude.handle_output(:stdout, line, state)
            {events ++ next, actions ++ more, state}
          end
        )

      assert Enum.map(Enum.reject(events, &(&1.type in [:status, :error])), & &1.type) ==
               Enum.map(expected, &elem(&1, 0))

      assert finished.session_id == state.session_id
      assert finished.usage.input_tokens == state.usage.input_tokens
      assert finished.usage.output_tokens == state.usage.output_tokens
      assert finished.usage.cost_usd == state.usage.cost_usd

      if unquote(status) == :succeeded do
        assert Enum.any?(
                 events,
                 &(&1.type == :tool_call and &1.data.name == "mcp__helmsman__whoami")
               )

        assert Enum.any?(events, &(&1.type == :tool_result and not &1.data.is_error))
      end
    end
  end

  defp collect(id, events) do
    receive do
      {:report, ^id, %Report.Events{events: next}, _, _, _} -> collect(id, events ++ next)
      {:report, ^id, %Report.Finished{} = finished, _, _, _} -> {finished, events}
      {:report, ^id, _, _, _, _} -> collect(id, events)
    after
      5_000 -> flunk("Claude replay did not finish")
    end
  end
end
