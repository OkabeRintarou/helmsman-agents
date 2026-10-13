defmodule HelmsmanDaemon.Adapters.ClaudeOutputTest do
  use ExUnit.Case, async: true
  alias HelmsmanDaemon.Adapters.Claude
  @fixtures Path.expand("../../fixtures/claude", __DIR__)

  for {name, reason} <- [
        {"error_auth", :provider_auth},
        {"error_network", :provider_network},
        {"error_model", :cli_error},
        {"error_api_400", :cli_error},
        {"error_session", :cli_error},
        {"error_root", :cli_error},
        {"error_quota", :provider_quota},
        {"error_context", :context_overflow},
        {"error_rate_limit", :provider_rate_limit},
        {"error_invalid_key", :provider_auth},
        {"resume_missing", :cli_error}
      ] do
    test "recorded #{name} normalizes and classifies" do
      name = unquote(name)
      {events, actions, state} = replay(name)

      code =
        @fixtures
        |> Path.join(name <> ".exit")
        |> File.read!()
        |> String.trim()
        |> String.to_integer()

      assert {{:failed, unquote(reason), error}, metadata} = Claude.finish(code, state)
      assert is_binary(error)
      refute Enum.any?(events, fn {type, data} -> type == :result and data.success end)

      if state.result do
        assert :close_stdin in actions

        assert Enum.take(
                 Enum.map(Enum.reject(events, &(elem(&1, 0) == :status)), &elem(&1, 0)),
                 -2
               ) == [:usage, :result]

        assert metadata.session_id != nil
        assert metadata.usage.input_tokens == 0
      end

      if name == "error_api_400", do: assert(error =~ "API Error: 400")
      if name == "error_session", do: assert(error =~ "No conversation found")
      if name == "error_root", do: assert(error =~ "root/sudo")
    end
  end

  test "non init system events are ignored and init creates session" do
    lines =
      File.read!(Path.join(@fixtures, "error_api_400.jsonl")) |> String.split("\n", trim: true)

    state = Claude.init_state(nil)

    for line <- lines, %{"type" => "system", "subtype" => subtype} <- [JSON.decode!(line)] do
      {events, [], _} = Claude.handle_output(:stdout, line, state)
      if subtype == "init", do: assert([{:session, _} | _] = events), else: assert(events == [])
    end
  end

  test "invalid UTF8 and malformed JSON warn without crashing; unknown objects ignored" do
    state = Claude.init_state(nil)

    for line <- [<<255, 254>>, "garbage", "null", String.duplicate("x", 500)] do
      assert {[{:status, %{level: :warning, message: message}}], [], ^state} =
               Claude.handle_output(:stdout, line, state)

      assert String.valid?(message)
      assert byte_size(message) < 250
    end

    assert {[], [], ^state} = Claude.handle_output(:stdout, ~s({"type":"unknown"}), state)
    assert {{:failed, :cli_error, error}, _} = Claude.finish(0, state)
    assert error =~ "without result"
  end

  test "stderr retains last 50 lines; observed model diagnostic warns without setting result" do
    state =
      Enum.reduce(1..60, Claude.init_state(nil), fn n, state ->
        {[], [], state} = Claude.handle_output(:stderr, "line #{n}", state)
        state
      end)

    assert length(state.stderr) == 50
    assert hd(state.stderr) == "line 11"
    line = File.read!(Path.join(@fixtures, "error_model.stderr")) |> String.trim()

    assert {[{:status, %{level: :warning}}], [], state} =
             Claude.handle_output(:stderr, line, state)

    assert state.result == nil
  end

  # add-run-steering 2.3 (decision 12): claude-adapter「中断与插话」, on
  # the live recordings of 2.1 (S1–S4, reviews/impl-notes-1.md, Claude 实测).
  @second "Also reply SECOND"
  @numbers "Reply with the numbers 1 to 30, one per line, and nothing else."

  # Replays `name` (stdout) through a state for `prompt`; `steer_at`
  # decides before which line the steering message 31 is written. Returns
  # the events and, per line, its actions.
  defp steer_replay(name, prompt, steer_at) do
    lines =
      @fixtures |> Path.join(name <> ".jsonl") |> File.read!() |> String.split("\n", trim: true)

    {events, actions, state, _written?} =
      lines
      |> Enum.with_index()
      |> Enum.reduce({[], [], Claude.init_state(%{prompt: prompt}), false}, fn
        {line, index}, {events, actions, state, written?} ->
          {state, written?} =
            if not written? and steer_at.(line, index, state) do
              assert {:ok, frame, :pending, state} = Claude.steer(31, @second, state)

              assert JSON.decode!(frame)["message"]["content"] == [
                       %{"type" => "text", "text" => @second}
                     ]

              {state, true}
            else
              {state, written?}
            end

          {next, more, state} = Claude.handle_output(:stdout, line, state)
          {events ++ next, actions ++ Enum.map(more, &{&1, index}), state, written?}
      end)

    {events, actions, state}
  end

  defp kinds(actions), do: for({action, _index} <- actions, do: action)

  defp line_type(line), do: JSON.decode!(line)["type"]

  defp first_text?(line) do
    case JSON.decode!(line) do
      %{"type" => "assistant", "message" => %{"content" => content}} ->
        Enum.any?(content, &(&1["type"] == "text"))

      _ ->
        false
    end
  end

  test "S1: merged into the turn — delivered at its echo, stdin closed at the one result" do
    {events, actions, state} =
      steer_replay(
        "steer_merged",
        "Run the Bash command `sleep 20`, then reply with exactly FIRST.",
        fn _l, i, _s -> i == 1 end
      )

    assert [{:steer_result, 31, :delivered}, :close_stdin] = kinds(actions)
    assert {:info, "steer delivered"} in for({:status, d} <- events, do: {d.level, d.message})
    assert state.steers == [] and state.prompt_echoed?
    assert {:succeeded, %{summary: summary}} = Claude.finish(0, state)
    assert summary =~ "SECOND"
  end

  for name <- ["steer_new_turn", "steer_eof"] do
    test "S2/S3 #{name}: written as the turn ends — stdin stays open until its own result" do
      {_events, actions, state} =
        steer_replay(unquote(name), @numbers, fn line, _i, _s -> first_text?(line) end)

      results = for {:close_stdin, i} <- actions, do: i
      [delivered] = for {{:steer_result, 31, :delivered}, i} <- actions, do: i

      lines =
        @fixtures
        |> Path.join(unquote(name) <> ".jsonl")
        |> File.read!()
        |> String.split("\n", trim: true)

      result_lines = for {line, i} <- Enum.with_index(lines), line_type(line) == "result", do: i
      assert [first, second] = result_lines
      assert first < delivered and delivered < second
      assert results == [second]
      assert state.closed? and state.steers == []
      assert {:succeeded, %{}} = Claude.finish(0, state)

      # Token counts add up; the cost is the session's last total.
      assert state.usage.input_tokens > 0
      assert state.usage.cost_usd == JSON.decode!(Enum.at(lines, second))["total_cost_usd"]
    end
  end

  # code-review-4 P1: an earlier result does not answer a message echoed (or
  # still waiting for its echo) after it.
  for {cut, label} <- [{:before_echo, "after the first result"}, {:at_echo, "after its echo"}] do
    test "S2 cut #{label}: exit 0 is a failure, not the first result's success" do
      lines =
        @fixtures
        |> Path.join("steer_new_turn.jsonl")
        |> File.read!()
        |> String.split("\n", trim: true)

      echo =
        Enum.find_index(lines, &match?(%{"type" => "user", "isReplay" => true}, JSON.decode!(&1)))

      echo =
        Enum.find_index(
          Enum.drop(lines, echo + 1),
          &match?(%{"isReplay" => true}, JSON.decode!(&1))
        ) +
          echo + 1

      first_result = Enum.find_index(lines, &(line_type(&1) == "result"))
      keep = if unquote(cut) == :before_echo, do: first_result + 1, else: echo + 1

      {_events, actions, state} =
        lines
        |> Enum.take(keep)
        |> Enum.with_index()
        |> Enum.reduce({[], [], Claude.init_state(%{prompt: @numbers})}, fn {line, index},
                                                                            {events, actions,
                                                                             state} ->
          state =
            if first_text?(line) and index < first_result do
              {:ok, _frame, :pending, state} = Claude.steer(31, @second, state)
              state
            else
              state
            end

          {next, more, state} = Claude.handle_output(:stdout, line, state)
          {events ++ next, actions ++ more, state}
        end)

      refute :close_stdin in actions

      assert {:steer_result, 31, :delivered} in actions == (unquote(cut) == :at_echo)

      assert {{:failed, :cli_error, message}, _} = Claude.finish(0, state)
      assert message =~ "before answering every steering message"
    end
  end

  test "S4: the resumed session remembers the steering message" do
    prompt = "List every message I have sent you in this session, one per line, quoted exactly."
    {_events, actions, state} = steer_replay("steer_resume", prompt, fn _l, _i, _s -> false end)
    assert kinds(actions) == [:close_stdin]
    assert state.prompt_echoed?
    assert {:succeeded, %{summary: summary}} = Claude.finish(0, state)
    assert summary =~ @second
  end

  test "stdin closed: unsupported; an error result closes stdin even with a message waiting" do
    {_, _, finished} = replay("error_auth")
    assert Claude.steer(31, "late", finished) == :unsupported

    state = Claude.init_state(%{prompt: "p"})
    {:ok, _frame, :pending, state} = Claude.steer(31, "x", state)
    error = JSON.encode!(%{"type" => "result", "is_error" => true, "result" => "boom"})

    assert {_events, [:close_stdin], %{closed?: true}} =
             Claude.handle_output(:stdout, error, state)
  end

  test "an echo is compared with the earliest waiting message only; no match, no receipt" do
    state = Claude.init_state(%{prompt: "p"})
    {:ok, _, :pending, state} = Claude.steer(31, "first", state)
    {:ok, _, :pending, state} = Claude.steer(32, "second", state)

    echo = fn text ->
      JSON.encode!(%{
        "type" => "user",
        "isReplay" => true,
        "message" => %{"role" => "user", "content" => [%{"type" => "text", "text" => text}]}
      })
    end

    assert {[], [], state} = Claude.handle_output(:stdout, echo.("p"), state)
    assert {[], [], ^state} = Claude.handle_output(:stdout, echo.("second"), state)
    assert {[], [], ^state} = Claude.handle_output(:stdout, echo.("firs"), state)

    assert {_, [{:steer_result, 31, :delivered}], state} =
             Claude.handle_output(:stdout, echo.("first"), state)

    assert {_, [{:steer_result, 32, :delivered}], state} =
             Claude.handle_output(:stdout, echo.("second"), state)

    assert state.steers == []
  end

  for name <-
        ~w(success_text success_tools success_mcp_tool resume_ok resume_cross_directory resume_interrupted model_fable model_opus model_sonnet effort_xhigh effort_max) do
    test "recorded #{name} succeeds with normalized events and metadata" do
      name = unquote(name)
      {events, actions, state} = replay(name)
      assert actions == [:close_stdin]

      assert Enum.take(Enum.map(Enum.reject(events, &(elem(&1, 0) == :status)), &elem(&1, 0)), -2) ==
               [:usage, :result]

      assert {:succeeded, metadata} = Claude.finish(0, state)
      assert metadata.session_id == state.result["session_id"]
      assert metadata.summary == state.result["result"]
      assert metadata.usage.input_tokens == state.result["usage"]["input_tokens"]
      assert metadata.usage.output_tokens == state.result["usage"]["output_tokens"]
      assert metadata.usage.cache_read_tokens == state.result["usage"]["cache_read_input_tokens"]

      assert metadata.usage.cache_write_tokens ==
               state.result["usage"]["cache_creation_input_tokens"]

      assert metadata.usage.cost_usd == state.result["total_cost_usd"]
      assert Enum.any?(events, fn {type, data} -> type == :result and data.success end)
      assert {{:failed, :cli_error, _}, _} = Claude.finish(1, state)

      for {type, data} <- events do
        assert {:ok, _} =
                 HelmsmanProtocol.Event.new(%{
                   seq: 1,
                   type: type,
                   data: data,
                   at: DateTime.utc_now()
                 })
      end
    end
  end

  test "MCP tool calls and text block results share the recorded ID" do
    {events, _, _} = replay("success_mcp_tool")

    assert Enum.map(events, &elem(&1, 0)) == [
             :session,
             :tool_call,
             :tool_result,
             :text,
             :usage,
             :result,
             :status
           ]

    assert {:tool_call, call} = Enum.find(events, &(elem(&1, 0) == :tool_call))
    assert call.name == "mcp__helmsman__whoami"
    assert call.input == "{}"
    assert {:tool_result, result} = Enum.find(events, &(elem(&1, 0) == :tool_result))
    assert result.call_id == call.call_id
    assert JSON.decode!(result.output)["workspace"]["name"] == "Claude probe"
    refute result.is_error
    refute result.truncated

    refute Enum.any?(events, fn {type, data} ->
             type == :status and data.message =~ "not connected"
           end)
  end

  test "Write missing is_error defaults false and real thinking is retained" do
    {events, _, _} = replay("success_tools")
    calls = for {:tool_call, call} <- events, do: call
    assert Enum.map(calls, & &1.name) == ["Write", "Bash"]
    results = for {:tool_result, result} <- events, do: result
    assert Enum.map(results, & &1.call_id) == Enum.map(calls, & &1.call_id)
    assert Enum.all?(results, &(not &1.is_error))
    {thinking, _, _} = replay("resume_cross_directory")
    assert Enum.any?(thinking, fn {type, data} -> type == :thinking and data.text != "" end)
  end

  test "recorded disconnected MCP warns and interrupted CLI has no successful result" do
    {events, _, _} = replay("mcp_disconnected")

    assert Enum.any?(events, fn {type, data} ->
             type == :status and data.message =~ "not connected"
           end)

    {_, actions, state} = replay("interrupted")
    assert actions == []
    assert {{:failed, :cli_error, error}, metadata} = Claude.finish(143, state)
    assert error =~ "without result"
    assert is_binary(metadata.session_id)
  end

  test "diagnostics are truncated and emitted once per tag without affecting success" do
    {_, _, state} = replay("success_text")
    line = "[claude-code:other] " <> String.duplicate("中", 500)

    assert {[{:status, %{message: message}}], [], state} =
             Claude.handle_output(:stderr, line, state)

    assert String.valid?(message) and byte_size(message) <= 1_050
    assert {[], [], state} = Claude.handle_output(:stderr, line, state)
    assert {:succeeded, _} = Claude.finish(0, state)
  end

  test "recorded tool structures obey UTF8 byte limits and unknown blocks are ignored" do
    lines =
      File.read!(Path.join(@fixtures, "success_tools.jsonl"))
      |> String.split("\n", trim: true)
      |> Enum.map(&JSON.decode!/1)

    call =
      Enum.find(lines, fn value ->
        Enum.any?(get_in(value, ["message", "content"]) || [], &(&1["type"] == "tool_use"))
      end)

    [block] = call["message"]["content"]

    call =
      put_in(call, ["message", "content"], [
        %{block | "input" => %{"content" => String.duplicate("中", 900)}}
      ])

    assert {[{:tool_call, data}], [], _} =
             Claude.handle_output(:stdout, JSON.encode!(call), Claude.init_state(nil))

    assert String.valid?(data.input) and byte_size(data.input) <= 2_048

    value = Enum.find(lines, &(&1["type"] == "user"))
    [block] = value["message"]["content"]

    value =
      put_in(value, ["message", "content"], [
        Map.merge(block, %{"content" => String.duplicate("中", 6_000), "is_error" => true}),
        %{"type" => "unknown"}
      ])

    assert {[{:tool_result, data}], [], _} =
             Claude.handle_output(:stdout, JSON.encode!(value), Claude.init_state(nil))

    assert String.valid?(data.output) and byte_size(data.output) <= 16_384
    assert data.truncated and data.is_error
  end

  test "large recorded result stays within protocol limits and summary is 4KB" do
    result =
      File.read!(Path.join(@fixtures, "success_text.jsonl"))
      |> String.split("\n", trim: true)
      |> Enum.map(&JSON.decode!/1)
      |> Enum.find(&(&1["type"] == "result"))

    result = %{result | "result" => String.duplicate("中", 12_000)}

    assert {[{:usage, _}, {:result, data}], [:close_stdin], state} =
             Claude.handle_output(:stdout, JSON.encode!(result), Claude.init_state(nil))

    assert String.valid?(data.text) and byte_size(data.text) <= 32_768
    assert {:succeeded, metadata} = Claude.finish(0, state)
    assert String.valid?(metadata.summary) and byte_size(metadata.summary) <= 4_096
  end

  test "zero exit without result always means CLI error even with authentication stderr" do
    {_, _, state} = Claude.handle_output(:stderr, "Invalid API key", Claude.init_state(nil))
    assert {{:failed, :cli_error, _}, _} = Claude.finish(0, state)
    assert {{:failed, :provider_auth, _}, _} = Claude.finish(1, state)
  end

  defp replay(name) do
    Enum.reduce(
      [{:stdout, ".jsonl"}, {:stderr, ".stderr"}],
      {[], [], Claude.init_state(nil)},
      fn {stream, ext}, initial ->
        @fixtures
        |> Path.join(name <> ext)
        |> File.read!()
        |> String.split("\n", trim: true)
        |> Enum.reduce(initial, fn line, {events, actions, state} ->
          {next, commands, state} = Claude.handle_output(stream, line, state)
          {events ++ next, actions ++ commands, state}
        end)
      end
    )
  end
end
