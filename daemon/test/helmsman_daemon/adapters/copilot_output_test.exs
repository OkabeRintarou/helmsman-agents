defmodule HelmsmanDaemon.Adapters.CopilotOutputTest do
  use HelmsmanDaemon.Case
  @moduletag :tmp_dir
  alias HelmsmanDaemon.Adapters.Copilot
  alias HelmsmanDaemon.Adapters.Copilot.Output
  @fixtures Path.expand("../../fixtures/copilot", __DIR__)

  defp replay(name) do
    run = spec(1)

    recorded =
      File.read!(Path.join(@fixtures, name <> ".jsonl"))
      |> String.split("\n", trim: true)
      |> Enum.map(&JSON.decode!/1)
      |> Enum.find(%{}, &(&1["type"] == "result"))

    run = %{run | resume_session_id: Map.get(recorded, "sessionId", "recorded")}
    state = Copilot.init_state(run)

    {events, actions, state} =
      Enum.reduce([:stderr, :stdout], {[], [], state}, fn stream, acc ->
        ext = if stream == :stderr, do: ".stderr", else: ".jsonl"

        Enum.reduce(
          String.split(File.read!(Path.join(@fixtures, name <> ext)), "\n", trim: true),
          acc,
          fn line, {events, actions, state} ->
            {next, more, state} = Copilot.handle_output(stream, line, state)
            {events ++ next, actions ++ more, state}
          end
        )
      end)

    code =
      @fixtures
      |> Path.join(name <> ".exit")
      |> File.read!()
      |> String.trim()
      |> String.to_integer()

    {events, actions, Copilot.finish(code, state), state}
  end

  test "MCP fixture event order, usage and success require both exit statuses" do
    {events, [], {:succeeded, info}, _} = replay("c3_mcp_toolcall")
    types = events |> Enum.reject(&(elem(&1, 0) == :status)) |> Enum.map(&elem(&1, 0))

    assert types == [
             :session,
             :text,
             :tool_call,
             :tool_result,
             :tool_call,
             :tool_result,
             :text,
             :usage,
             :result
           ]

    assert {:tool_call, %{name: "helmsman-whoami"}} =
             Enum.find(events, &(elem(&1, 0) == :tool_call))

    assert {:tool_result, %{output: "helmsman-ok", is_error: false}} =
             Enum.find(events, &(elem(&1, 0) == :tool_result))

    assert info.usage.input_tokens == 39_141
    assert info.usage.output_tokens == 483
    assert info.usage.reasoning_tokens == 320
    assert info.usage.premium_requests == 0

    for name <- ~w(result_nonzero process_nonzero) do
      {_, _, {{:failed, :cli_error, message}, _}, _} = replay(name)
      assert message =~ "1"
    end
  end

  for {name, reason} <- [
        {"c2_error_not_logged_in", :provider_auth},
        {"c10_error_auth_badtoken_nogh", :provider_auth},
        {"c10_error_network", :provider_network},
        {"c10_error_context_too_long", :context_overflow},
        {"c7_resume_missing", :cli_error},
        {"c10_error_model", :cli_error},
        {"c9_effort_max_gpt5mini", :cli_error},
        {"c8_interrupt_sigterm", :cli_error}
      ] do
    test "classifies #{name}" do
      assert {_, _, {{:failed, unquote(reason), _}, _}, _} = replay(unquote(name))
    end
  end

  test "all text patterns and session error types have attributed fixtures" do
    reasons = [
      :provider_auth,
      :provider_auth,
      :provider_auth,
      :provider_auth,
      :provider_quota,
      :provider_quota,
      :provider_quota,
      :provider_rate_limit,
      :context_overflow,
      :context_overflow,
      :context_overflow,
      :context_overflow,
      :provider_network,
      :provider_network,
      :provider_network,
      :provider_network,
      :provider_network,
      :provider_network,
      :cli_error,
      :cli_error,
      :cli_error
    ]

    for {reason, index} <- Enum.with_index(reasons) do
      name = "pattern_" <> String.pad_leading(to_string(index), 2, "0")
      assert {_, _, {{:failed, ^reason, _}, _}, _} = replay(name)
      assert File.exists?(Path.join(@fixtures, name <> ".source"))
    end

    for {type, reason} <- [
          {"authentication", :provider_auth},
          {"authorization", :provider_auth},
          {"quota", :provider_quota},
          {"rate_limit", :provider_rate_limit},
          {"context_limit", :context_overflow},
          {"query", :cli_error}
        ] do
      assert {_, _, {{:failed, ^reason, _}, _}, _} = replay("session_error_" <> type)
    end
  end

  test "MCP guard aborts only connected unexpected servers; Helmsman failure warns" do
    {_, actions, {{:failed, :cli_error, message}, _}, _} = replay("c5_dyn_noflags")
    assert message =~ "rogue_home"
    assert [{:abort, :cli_error, _}] = actions
    {events, [], _, _} = replay("c4_mcp_down_free")

    assert Enum.any?(events, fn {type, data} ->
             type == :status and data.message =~ "Helmsman MCP"
           end)

    run = spec(1)
    run = %{run | agent: %{run.agent | extra_mcp_servers: %{"extra" => %{}}}}
    state = Copilot.init_state(run)

    assert {_, [], _} =
             Copilot.handle_output(
               :stdout,
               ~s({"type":"session.mcp_servers_loaded","data":{"servers":[{"name":"extra","status":"connected"},{"name":"unknown","status":"disabled"}]}}),
               state
             )

    assert {_, [{:abort, :cli_error, _}], _} =
             Copilot.handle_output(
               :stdout,
               ~s({"type":"session.mcp_servers_loaded","data":{"servers":[{"name":"rogue","status":"connected","source":"user"}]}}),
               state
             )
  end

  test "recorded untrusted repository loads only configured Helmsman MCP" do
    {events, [], _finished, _state} = replay("c5_dyn_isolated")

    refute Enum.any?(events, fn {type, data} ->
             type == :status and String.contains?(data.message, "did not configure")
           end)

    recording = File.read!(Path.join(@fixtures, "c5_dyn_isolated.jsonl"))

    servers =
      recording
      |> String.split("\n", trim: true)
      |> Enum.map(&JSON.decode!/1)
      |> Enum.filter(
        &(&1["type"] == "session.mcp_server_status_changed" and
            &1["data"]["status"] == "connected")
      )
      |> Enum.map(& &1["data"]["serverName"])

    assert servers == ["helmsman"]
  end

  test "unknown and invalid output, reasoning, truncation, usage sum and interrupt" do
    state = Copilot.init_state(spec(1))
    assert {[{:status, _}], [], ^state} = Copilot.handle_output(:stdout, "invalid", state)

    assert {[{:session, _}], [], state} =
             Copilot.handle_output(:stdout, ~s({"type":"unknown"}), state)

    assert {[], [], ^state} =
             Copilot.handle_output(
               :stdout,
               ~s({"type":"assistant.message_delta","data":{"content":"ignored"}}),
               state
             )

    assert {[], [], ^state} =
             Copilot.handle_output(
               :stdout,
               ~s({"type":"assistant.message","data":{"content":""}}),
               state
             )

    assert {[{:thinking, %{text: "reason"}}], [], _} =
             Copilot.handle_output(
               :stdout,
               ~s({"type":"assistant.reasoning","data":{"content":"reason"}}),
               state
             )

    line =
      JSON.encode!(%{
        type: "tool.execution_complete",
        data: %{
          toolCallId: "id",
          success: false,
          result: %{content: String.duplicate("中", 10_000)}
        }
      })

    assert {[{:tool_result, result}], [], _} = Copilot.handle_output(:stdout, line, state)
    assert result.truncated and result.is_error
    assert byte_size(result.output) <= 16_384 and String.valid?(result.output)
    assert {{:failed, :cli_error, _}, _} = Copilot.finish(0, state)
    assert Copilot.interrupt(state) == :signal
    assert Copilot.steer(:ref, "text", state) == :unsupported

    usage =
      Output.usage(
        %{
          "modelMetrics" => %{
            "a" => %{
              "usage" => %{"inputTokens" => 10, "outputTokens" => 3, "reasoningTokens" => 2}
            },
            "b" => %{
              "usage" => %{"inputTokens" => 20, "outputTokens" => 4, "reasoningTokens" => 1}
            }
          }
        },
        %{"premiumRequests" => 0.5}
      )

    assert usage.input_tokens == 30 and usage.output_tokens == 7 and usage.reasoning_tokens == 3 and
             usage.premium_requests == 0.5
  end
end
