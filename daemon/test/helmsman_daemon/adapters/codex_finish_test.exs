defmodule HelmsmanDaemon.Adapters.CodexFinishTest do
  use HelmsmanDaemon.Case
  @moduletag :tmp_dir
  alias HelmsmanDaemon.Adapters.Codex
  alias HelmsmanDaemon.Adapters.Codex.Output
  alias HelmsmanDaemon.CodexFixtures

  for {name, reason} <- [
        {"error_auth", :provider_auth},
        {"error_model", :cli_error},
        {"error_quota", :provider_quota},
        {"error_context", :context_overflow},
        {"error_rate_limit", :provider_rate_limit}
      ] do
    test "classifies real #{name}" do
      {_, _, state} = CodexFixtures.replay(unquote(name), spec(1))
      assert {{:failed, unquote(reason), message}, _} = Codex.finish(0, state)

      if unquote(reason) == :provider_auth,
        do: assert(message =~ Path.join(Paths.home(), "codex"))
    end
  end

  test "schema derived failures replay and missing-code context remains recoverable" do
    for {code, reason} <- [
          {"rateLimitExceeded", :provider_rate_limit},
          {"usageLimitExceeded", :provider_quota},
          {"contextWindowExceeded", :context_overflow}
        ] do
      {_, _, state} = CodexFixtures.replay("schema_" <> code, spec(1))
      assert {{:failed, ^reason, _}, _} = Codex.finish(0, state)
    end

    for code <- [nil, "badRequest", "other"] do
      state = %{
        Codex.init_state(spec(1))
        | error: %{"codexErrorInfo" => code, "additionalDetails" => "CONTEXT_LENGTH_EXCEEDED"}
      }

      assert {{:failed, :context_overflow, _}, _} = Codex.finish(0, state)
    end
  end

  test "classifies schema errors and all HTTP status objects" do
    for {code, reason} <- [
          {"unauthorized", :provider_auth},
          {"usageLimitExceeded", :provider_quota},
          {"rateLimitExceeded", :provider_rate_limit},
          {"serverOverloaded", :provider_rate_limit},
          {"contextWindowExceeded", :context_overflow},
          {"internalServerError", :provider_network},
          {"responseTooManyFailedAttempts", :provider_network},
          {"badRequest", :cli_error},
          {"sessionBudgetExceeded", :cli_error},
          {"sandboxError", :cli_error},
          {"other", :cli_error},
          {nil, :cli_error}
        ] do
      assert Output.classify(code) == reason
    end

    for kind <-
          ~w(httpConnectionFailed responseStreamConnectionFailed responseStreamDisconnected responseTooManyFailedAttempts),
        {status, reason} <- [
          {401, :provider_auth},
          {403, :provider_auth},
          {429, :provider_rate_limit},
          {408, :provider_network},
          {400, :cli_error},
          {503, :provider_network},
          {nil, :provider_network}
        ] do
      assert Output.classify(%{kind => %{"httpStatusCode" => status}}) == reason
    end
  end

  test "missing result, resume error and nonzero exit are failures" do
    assert {{:failed, :cli_error, "exited before the turn completed"}, %{usage: usage}} =
             Codex.finish(0, Codex.init_state(spec(1)))

    assert usage.input_tokens == nil
    run = %{spec(1) | resume_session_id: "missing"}
    {_, _, state} = CodexFixtures.replay("resume_missing", run)
    assert {{:failed, :cli_error, error}, %{session_id: nil}} = Codex.finish(0, state)
    assert error =~ "session cannot be resumed: "
    {_, _, state} = Codex.handle_output(:stderr, "diagnostic", Codex.init_state(spec(1)))
    assert {{:failed, :cli_error, error}, _} = Codex.finish(2, state)
    assert error =~ "exit 2"
    assert error =~ "diagnostic"
  end

  test "summary truncates safely and errors strip URL credentials and queries" do
    state = %{
      Codex.init_state(spec(1))
      | text: String.duplicate("界", 2_000),
        result: %{"status" => "completed"}
    }

    assert {:succeeded, %{summary: summary}} = Codex.finish(0, state)
    assert byte_size(summary) <= 4_096
    assert String.valid?(summary)

    error = %{
      "codexErrorInfo" => "other",
      "message" => "failed at https://user:SECRET@example.test/path?token=SECRET"
    }

    assert {{:failed, :cli_error, text}, _} = Codex.finish(0, %{state | error: error})
    assert text =~ "https://example.test/path"
    refute text =~ "SECRET"
  end

  test "error-only sanitation handles uppercase schemes and fragments in results and status" do
    url = "HTTPS://user:SECRET@example.test/path?key=SECRET#SECRET"
    state = %{Codex.init_state(spec(1)) | session_id: "t-1"}

    for method <- ["error", "mcpServer/startupStatus/updated", "warning"] do
      params =
        case method do
          "error" ->
            %{"threadId" => "t-1", "willRetry" => true, "error" => %{"message" => url}}

          "mcpServer/startupStatus/updated" ->
            %{"name" => "helmsman", "status" => "failed", "error" => url}

          "warning" ->
            %{"message" => url}
        end

      {[{:status, data}], [], _} =
        Codex.handle_output(
          :stdout,
          JSON.encode!(%{"method" => method, "params" => params}),
          state
        )

      refute data.message =~ "SECRET"
      refute data.message =~ "?"
      refute data.message =~ "#"
    end

    assert {{:failed, :cli_error, text}, _} =
             Codex.finish(0, %{state | error: %{"message" => url}})

    refute text =~ "SECRET"
  end

  test "normal URL queries remain unchanged in text, tool parameters, result and summary" do
    text = "Open https://example.test/search?q=elixir&sort=date#section"
    state = %{Codex.init_state(spec(1)) | session_id: "t-1"}

    {[{:text, %{text: ^text}}], [], state} =
      Codex.handle_output(
        :stdout,
        JSON.encode!(%{
          "method" => "item/completed",
          "params" => %{"item" => %{"type" => "agentMessage", "text" => text}}
        }),
        state
      )

    {[{:tool_call, call}, {:tool_result, _}], [], state} =
      Codex.handle_output(
        :stdout,
        JSON.encode!(%{
          "method" => "item/completed",
          "params" => %{
            "item" => %{
              "type" => "mcpToolCall",
              "id" => "call",
              "server" => "helmsman",
              "tool" => "whoami",
              "arguments" => %{"url" => text},
              "status" => "completed",
              "result" => %{"content" => []}
            }
          }
        }),
        state
      )

    assert JSON.decode!(call.input) == %{"url" => text}

    {events, [:close_stdin], state} =
      Codex.handle_output(
        :stdout,
        JSON.encode!(%{
          "method" => "turn/completed",
          "params" => %{"threadId" => "t-1", "turn" => %{"id" => "u-1", "status" => "completed"}}
        }),
        state
      )

    assert {:result, %{text: text, success: true}} in events
    assert {:succeeded, %{summary: ^text}} = Codex.finish(0, state)
  end
end
