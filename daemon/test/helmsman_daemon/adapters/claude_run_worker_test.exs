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

  # add-run-steering 2.3: the S2 recording (written as the turn ends; a turn
  # of its own) through RunWorker. The fake CLI waits for the steering frame
  # before the first result, as the real CLI got it.
  test "RunWorker delivers steering to Claude, acknowledges it and finishes after its turn",
       %{tmp_dir: dir} do
    lines =
      @fixtures
      |> Path.join("steer_new_turn.jsonl")
      |> File.read!()
      |> String.split("\n", trim: true)

    first_text =
      Enum.find_index(lines, fn line ->
        match?(%{"type" => "assistant", "message" => %{"content" => [_ | _]}}, JSON.decode!(line)) and
          Enum.any?(JSON.decode!(line)["message"]["content"], &(&1["type"] == "text"))
      end)

    {before, rest} = Enum.split(lines, first_text + 1)

    scenario =
      Enum.map_join(before, "", &("json " <> &1 <> "\n")) <>
        "await_line Also reply SECOND\n" <>
        Enum.map_join(rest, "", &("json " <> &1 <> "\n")) <> "await_stdin_eof\nexit 0\n"

    run = spec(2, scenario!(Path.join(dir, "steer"), scenario))
    start_supervised!({RunWorker, {run, [adapter: ClaudeReplay, reporter: TestReporter]}})
    assert_receive {:report, 2, %Report.Started{}, _, _, _}, 2_000
    Runs.steer(2, 31, "Also reply SECOND")

    assert_receive {:report, 2, %Report.SteerAck{run_id: 2, feedback_id: 31}, _, _, _}, 5_000
    {finished, _events} = collect(2, [])
    assert finished.status == :succeeded
  end

  # code-review-4 P1, through RunWorker: the CLI exits 0 after the echo of
  # the steering message (acknowledged) but before its result, or after the
  # first result before any echo (not acknowledged). Both runs fail.
  for {cut, acked?} <- [{:at_echo, true}, {:before_echo, false}] do
    test "RunWorker fails a Claude run that exits #{cut} without answering steering",
         %{tmp_dir: dir} do
      lines =
        @fixtures
        |> Path.join("steer_new_turn.jsonl")
        |> File.read!()
        |> String.split("\n", trim: true)

      first_text =
        Enum.find_index(lines, fn line ->
          Enum.any?(JSON.decode!(line)["message"]["content"] || [], &(&1["type"] == "text"))
        end)

      first_result = Enum.find_index(lines, &(JSON.decode!(&1)["type"] == "result"))

      echo =
        Enum.find_index(lines, fn line ->
          match?(
            %{
              "isReplay" => true,
              "message" => %{"content" => [%{"text" => "Also reply SECOND"}]}
            },
            JSON.decode!(line)
          )
        end)

      keep = if unquote(cut) == :at_echo, do: echo + 1, else: first_result + 1
      {before, rest} = Enum.split(Enum.take(lines, keep), first_text + 1)

      scenario =
        Enum.map_join(before, "", &("json " <> &1 <> "\n")) <>
          "await_line Also reply SECOND\n" <>
          Enum.map_join(rest, "", &("json " <> &1 <> "\n")) <> "exit 0\n"

      run = spec(3, scenario!(Path.join(dir, "cut"), scenario))
      start_supervised!({RunWorker, {run, [adapter: ClaudeReplay, reporter: TestReporter]}})
      assert_receive {:report, 3, %Report.Started{}, _, _, _}, 2_000
      Runs.steer(3, 31, "Also reply SECOND")

      reports = payloads(3, [])

      assert %Report.Finished{status: :failed, failure_reason: :cli_error} =
               finished = List.last(reports)

      assert finished.error =~ "before answering every steering message"
      acks = for %Report.SteerAck{feedback_id: id} <- reports, do: id
      assert acks == if(unquote(acked?), do: [31], else: [])
    end
  end

  # update-claude-setting-sources: the variable that loads the repository's
  # CLAUDE.md wins over the Agent's env.
  test "the Agent env cannot turn off the repository CLAUDE.md variable", %{tmp_dir: dir} do
    scenario =
      ~S(sh printf '{"type":"assistant","message":{"content":[{"type":"text","text":"md=%s"}]}}\n' "$CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD") <>
        "\n" <>
        ~S(json {"type":"result","is_error":false,"result":"OK","session_id":"s-1"}) <>
        "\nawait_stdin_eof\nexit 0\n"

    run = spec(5, scenario!(Path.join(dir, "env"), scenario))

    run = %{
      run
      | agent: %{run.agent | env: %{"CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD" => "0"}}
    }

    start_supervised!({RunWorker, {run, [adapter: ClaudeReplay, reporter: TestReporter]}})
    {finished, events} = collect(run.run_id, [])
    assert finished.status == :succeeded
    assert Enum.any?(events, &(&1.type == :text and &1.data.text == "md=1"))
  end

  defp payloads(id, acc) do
    receive do
      {:report, ^id, %Report.Finished{} = finished, _, _, _} -> Enum.reverse([finished | acc])
      {:report, ^id, payload, _, _, _} -> payloads(id, [payload | acc])
    after
      5_000 -> flunk("Claude replay did not finish")
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
