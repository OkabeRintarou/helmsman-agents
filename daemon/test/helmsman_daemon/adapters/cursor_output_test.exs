defmodule HelmsmanDaemon.Adapters.CursorOutputTest do
  use ExUnit.Case, async: true
  alias HelmsmanDaemon.Adapters.Cursor
  alias HelmsmanDaemon.Adapters.Cursor.Output
  @fixtures Path.expand("../../fixtures/cursor", __DIR__)

  defp spec(extra \\ %{}, model \\ nil) do
    run = HelmsmanDaemon.Case.spec(1)
    %{run | agent: %{run.agent | provider: :cursor, extra_mcp_servers: extra, model: model}}
  end

  defp read(name, ext), do: File.read!(Path.join(@fixtures, name <> ext))

  defp replay(name, run \\ spec()) do
    state = Cursor.init_state(run)

    {events, actions, state} =
      Enum.reduce(
        Enum.map(String.split(read(name, ".jsonl"), "\n", trim: true), &{:stdout, &1}) ++
          Enum.map(String.split(read(name, ".stderr"), "\n", trim: true), &{:stderr, &1}),
        {[], [], state},
        fn {stream, line}, {events, actions, state} ->
          {new, more, state} = Cursor.handle_output(stream, line, state)
          {events ++ new, actions ++ more, state}
        end
      )

    code = read(name, ".exit") |> String.trim() |> String.to_integer()
    {result, metadata} = Cursor.finish(code, state)
    %{events: events, actions: actions, result: result, metadata: metadata}
  end

  defp types(events), do: Enum.map(events, &elem(&1, 0))

  test "a Helmsman MCP tool call" do
    replay = replay("mcp_tool_force")
    assert replay.result == :succeeded
    assert replay.actions == []
    assert [{:session, %{session_id: id}} | _] = replay.events
    assert id == "4b42c4bb-7868-421b-9926-16e5d56f6d05"

    calls = for {:tool_call, call} <- replay.events, do: call
    assert Enum.map(calls, & &1.name) == ["getMcpTools", "helmsman-whoami"]
    assert Enum.all?(calls, &(not String.contains?(&1.call_id, "\n")))
    [_, whoami] = calls

    assert [%{output: "helmsman-ok", is_error: false}] =
             for({:tool_result, %{call_id: id} = r} <- replay.events, id == whoami.call_id, do: r)

    order = replay.events |> types() |> Enum.uniq()

    assert order -- [:thinking, :status] == [
             :session,
             :text,
             :tool_call,
             :tool_result,
             :usage,
             :result
           ]

    assert {:result, %{success: true}} = List.last(replay.events)

    assert {:usage,
            %{
              input_tokens: 6186,
              output_tokens: 617,
              cache_read_tokens: 29_440,
              cache_write_tokens: 0
            }} =
             Enum.find(replay.events, &match?({:usage, _}, &1))

    assert replay.metadata.summary == "helmsman-ok\nMANGO\nPINEAPPLE"
    assert replay.metadata.session_id == id
  end

  test "the repository's MCP servers never appear; only helmsman is called" do
    for name <- ~w(mcp_tool_force cli_json_disabled approve_mcps) do
      replay = replay(name)
      refute Enum.any?(replay.actions, &match?({:abort, _, _}, &1)), name
    end
  end

  test "a Helmsman tool blocked by the repository's configuration" do
    replay = replay("cli_json_deny")

    assert [%{is_error: true, output: output} | _] =
             for({:tool_result, %{is_error: true} = r} <- replay.events, do: r)

    assert output =~ "Blocked by permissions configuration"

    assert Enum.any?(replay.events, fn
             {:status, %{level: :warning, message: message}} ->
               message =~ "Cursor rejected the Helmsman tool helmsman-whoami"

             _ ->
               false
           end)
  end

  test "rejected tool calls are errors with their reason" do
    replay = replay("mcp_tool_noforce")

    assert Enum.any?(
             replay.events,
             &match?(
               {:tool_result, %{is_error: true, output: "User rejected MCP: helmsman-whoami"}},
               &1
             )
           )
  end

  test "shell, edit and read tools" do
    replay = replay("unattended_force")
    names = for {:tool_call, %{name: name}} <- replay.events, do: name
    assert "shell" in names and "edit" in names
    assert Enum.any?(replay.events, &match?({:tool_call, %{name: "shell", input: "pwd"}}, &1))

    assert Enum.any?(
             replay.events,
             &match?({:tool_result, %{output: "<WORK>/w5\n", is_error: false}}, &1)
           )

    assert "read" in for({:tool_call, %{name: name}} <- replay("approve_mcps").events, do: name)
  end

  test "an MCP server Helmsman did not configure aborts the run" do
    line =
      JSON.encode!(%{
        "type" => "tool_call",
        "subtype" => "started",
        "call_id" => "c1\nx",
        "tool_call" => %{
          "mcpToolCall" => %{"args" => %{"name" => "rogue-x", "providerIdentifier" => "rogue"}}
        }
      })

    state = Cursor.init_state(spec())

    assert {[], [{:abort, :cli_error, message}], state} =
             Cursor.handle_output(:stdout, line, state)

    assert message =~ "rogue"
    assert {[], [], _} = Cursor.handle_output(:stdout, line, state)

    state = Cursor.init_state(spec(%{"rogue" => %{"url" => "http://r.invalid"}}))

    assert {[{:tool_call, %{call_id: "c1x", name: "rogue-x"}}], [], _} =
             Cursor.handle_output(:stdout, line, state)
  end

  test "credentials not from the environment abort the run" do
    line = ~s({"type":"system","subtype":"init","apiKeySource":"login","session_id":"s"})

    assert {[], [{:abort, :cli_error, "Cursor did not use CURSOR_API_KEY"}], _} =
             Cursor.handle_output(:stdout, line, Cursor.init_state(spec()))
  end

  test "reconnects and retries are information; bad lines are warnings" do
    replay = replay("exclude_ws_context")

    infos = for {:status, %{level: :info, message: m}} <- replay.events, do: m
    assert Enum.any?(infos, &(&1 =~ "reconnecting")) and Enum.any?(infos, &(&1 =~ "retrying"))
    assert {:failed, :cli_error, _} = replay.result

    assert {[{:status, %{level: :warning}}], [], _} =
             Cursor.handle_output(:stdout, "not json", Cursor.init_state(spec()))
  end

  for {name, reason} <- [
        {"error_auth_nokey", :provider_auth},
        {"error_auth_invalid", :provider_auth},
        {"error_network_proxy", :provider_network},
        {"error_network_endpoint", :provider_network},
        {"error_rate_limit", :provider_rate_limit},
        {"error_quota", :provider_quota},
        {"error_context", :context_overflow},
        {"error_trust", :cli_error},
        {"sandbox_enabled", :cli_error},
        {"resume_missing", :cli_error}
      ] do
    test "#{name} fails with #{reason}" do
      assert {:failed, unquote(reason), _} = replay(unquote(name)).result
    end
  end

  test "an unavailable model and a bad chat ID are explained" do
    assert {:failed, :cli_error,
            "model nonexistent-model-xyz is not available to this Cursor account"} =
             replay("error_model", spec(%{}, "nonexistent-model-xyz")).result

    assert {:failed, :cli_error, message} = replay("resume_badid").result
    assert message =~ "can no longer be resumed"
  end

  test "classification follows the decision's order and patterns" do
    for {text, reason} <- [
          {"NOT_LOGGED_IN", :provider_auth},
          {"AUTH_TOKEN_EXPIRED", :provider_auth},
          {"UNAUTHORIZED", :provider_auth},
          {"BAD_API_KEY", :provider_auth},
          {"USAGE_LIMIT", :provider_quota},
          {"RESOURCE_EXHAUSTED", :provider_quota},
          {"USAGE_PRICING_REQUIRED", :provider_quota},
          {"RATE_LIMIT", :provider_rate_limit},
          {"CONVERSATION_TOO_LONG", :context_overflow},
          {"MAX_TOKENS", :context_overflow},
          {"read ECONNRESET", :provider_network},
          {"connect ECONNREFUSED", :provider_network},
          {"ETIMEDOUT", :provider_network},
          {"socket hang up", :provider_network},
          {"NGHTTP2_ENHANCE_YOUR_CALM", :provider_network},
          {"ActionRequiredError: Request blocked", :cli_error}
        ],
        do: assert(Output.classify(text) == reason, text)
  end

  test "result flagged as an error, a clean exit without result, and an interrupted run" do
    state = Cursor.init_state(spec())
    line = ~s({"type":"result","subtype":"success","is_error":true,"result":"boom"})
    {_, _, errored} = Cursor.handle_output(:stdout, line, state)
    assert {{:failed, :cli_error, "boom"}, _} = Cursor.finish(0, errored)
    assert {{:failed, :cli_error, message}, _} = Cursor.finish(0, state)
    assert message =~ "without a result"

    # Exit 143 without a result: what the daemon reports for a run it
    # stopped is its own reason (RunWorker never asks the adapter).
    assert {:failed, :cli_error, _} = replay("interrupted").result
  end

  test "summary falls back to the result text" do
    state = Cursor.init_state(spec())

    {_, _, state} =
      Cursor.handle_output(:stdout, ~s({"type":"result","is_error":false,"result":"all"}), state)

    assert {:succeeded, %{summary: "all"}} = Cursor.finish(0, state)
  end

  test "a new session's own recording" do
    replay = replay("new_session")
    assert replay.result == :succeeded
    assert replay.metadata.summary == "OK"
  end

  test "steering is not supported; stopping signals the group" do
    assert Cursor.steer(1, "x", Cursor.init_state(spec())) == :unsupported
    assert Cursor.interrupt(nil) == :signal
    assert Cursor.track_descendants?()
  end
end
