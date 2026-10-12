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

  test "default interruption and steering before and after a recorded final result" do
    state = Claude.init_state(nil)
    assert Claude.interrupt(state) == :signal
    assert {:ok, frame, ^state} = Claude.steer("Also update the README", state)
    assert String.ends_with?(frame, "\n")

    assert JSON.decode!(frame)["message"]["content"] == [
             %{"type" => "text", "text" => "Also update the README"}
           ]

    {_, _, finished} = replay("error_auth")
    assert Claude.steer("late", finished) == :unsupported
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
