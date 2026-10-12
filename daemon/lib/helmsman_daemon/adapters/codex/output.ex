defmodule HelmsmanDaemon.Adapters.Codex.Output do
  @moduledoc false
  alias HelmsmanDaemon.Adapters.Codex
  alias HelmsmanDaemon.Adapters.Codex.Config
  alias HelmsmanProtocol.Event
  @retry_budget_ms 300_000
  @tools ~w(commandExecution fileChange mcpToolCall webSearch)

  def init(spec) do
    {servers, _} = Config.mcp(spec)

    %{
      spec: spec,
      session_id: nil,
      turn_id: nil,
      closed?: false,
      result: nil,
      error: nil,
      fatal: nil,
      retry_started_at: nil,
      retry_error: nil,
      abandoned: nil,
      clock:
        Application.get_env(:helmsman_daemon, :codex_clock, fn ->
          System.monotonic_time(:millisecond)
        end),
      text: "",
      stderr: [],
      tools: MapSet.new(),
      usage_by_turn: %{},
      usage: empty_usage(),
      allowed_servers: MapSet.new(Map.keys(servers)),
      next_steer: 100,
      pending_steers: MapSet.new()
    }
  end

  def handle(:stderr, line, state),
    do: {[], [], %{state | stderr: Enum.take(state.stderr ++ [safe(line, 4_096)], -50)}}

  def handle(:stdout, line, state) do
    case JSON.decode(line) do
      {:ok, value} when is_map(value) -> output(value, progress(value, state))
      _ -> {Codex.warning("Invalid Codex JSON: " <> safe_error(line, 200)), [], state}
    end
  end

  defp output(%{"id" => id, "method" => method} = request, state),
    do: server_request(id, method, request["params"] || %{}, state)

  defp output(%{"id" => id, "error" => error}, state) when id in [1, 2, 3] do
    prefix =
      if id == 2 and state.spec.resume_session_id, do: "session cannot be resumed: ", else: ""

    {[], [:close_stdin],
     %{
       state
       | fatal: prefix <> error_text(error),
         session_id: if(prefix != "", do: nil, else: state.session_id),
         closed?: true
     }}
  end

  defp output(%{"id" => 2, "result" => %{"thread" => %{"id" => id}}}, %{closed?: false} = state)
       when is_binary(id) do
    params =
      %{"threadId" => id, "input" => [%{"type" => "text", "text" => state.spec.prompt}]}
      |> Codex.optional("effort", state.spec.agent.effort)

    {[{:session, %{session_id: id}}],
     [{:write, Codex.frame(%{"id" => 3, "method" => "turn/start", "params" => params})}],
     %{state | session_id: id}}
  end

  defp output(%{"id" => 3, "result" => %{"turn" => %{"id" => id}}}, state),
    do: {[], [], %{state | turn_id: id}}

  defp output(%{"id" => id} = reply, state) do
    if MapSet.member?(state.pending_steers, id) do
      events =
        if reply["error"],
          do: Codex.warning("steer rejected: " <> safe_error(error_text(reply["error"]), 1_024)),
          else: [{:status, %{level: :info, message: "steer delivered"}}]

      {events, [], %{state | pending_steers: MapSet.delete(state.pending_steers, id)}}
    else
      {[], [], state}
    end
  end

  defp output(%{"method" => "mcpServer/startupStatus/updated", "params" => params}, state),
    do: mcp_status(params, state)

  defp output(
         %{
           "method" => "turn/started",
           "params" => %{"threadId" => thread, "turn" => %{"id" => id}}
         },
         %{session_id: thread} = state
       ),
       do: {[], [], %{state | turn_id: id}}

  defp output(
         %{"method" => "turn/completed", "params" => %{"threadId" => thread, "turn" => turn}},
         %{session_id: thread, closed?: false} = state
       ) do
    usage = Map.get(state.usage_by_turn, turn["id"], empty_usage())

    events = [
      {:usage, usage},
      {:result,
       %{
         text: safe(state.text, 32_768),
         success: turn["status"] == "completed" and is_nil(state.fatal)
       }}
    ]

    {events, [:close_stdin],
     %{
       state
       | result: turn,
         turn_id: turn["id"],
         closed?: true,
         usage: usage,
         error: turn["error"] || state.error
     }}
  end

  defp output(
         %{"method" => "thread/tokenUsage/updated", "params" => %{"threadId" => thread} = params},
         %{session_id: thread} = state
       ),
       do: token_usage(params, state)

  defp output(
         %{"method" => "error", "params" => %{"threadId" => thread} = params},
         %{session_id: thread} = state
       ) do
    if params["willRetry"] == true,
      do: retry_error(params["error"] || %{}, state),
      else: {[], [], %{state | error: params["error"]}}
  end

  defp output(%{"method" => method, "params" => %{"item" => item}}, state)
       when method in ["item/started", "item/completed"], do: item(method, item, state)

  defp output(%{"method" => method, "params" => params}, state)
       when method in [
              "configWarning",
              "warning",
              "deprecationNotice",
              "model/rerouted",
              "thread/compacted"
            ] do
    level = if method in ["model/rerouted", "thread/compacted"], do: :info, else: :warning

    {[
       {:status,
        %{
          level: level,
          message: safe_error(params["message"] || params["summary"] || method, 1_024)
        }}
     ], [], state}
  end

  defp output(_, state), do: {[], [], state}

  defp progress(
         %{"method" => method, "params" => %{"threadId" => thread}},
         %{session_id: thread} = state
       ) do
    if String.starts_with?(method, "item/") or
         method in ["thread/tokenUsage/updated", "turn/completed"],
       do: %{state | retry_started_at: nil, retry_error: nil},
       else: state
  end

  defp progress(_, state), do: state

  defp retry_error(_error, %{closed?: true} = state), do: {[], [], state}

  defp retry_error(error, state) do
    now = state.clock.()
    started = state.retry_started_at || now
    state = %{state | retry_started_at: started, retry_error: error}

    if now - started >= @retry_budget_ms do
      {:failed, reason, text} = failure(error)

      reason =
        if reason == :cli_error and is_nil(error["codexErrorInfo"]),
          do: :provider_network,
          else: reason

      message =
        "Codex kept retrying the model provider for more than 5 minutes; last error: " <> text

      actions = abandon_actions(state)

      {Codex.warning(safe_error(message, 1_024)), actions,
       %{state | abandoned: {:failed, reason, message}, closed?: true}}
    else
      {Codex.warning(safe_error(error_text(error), 1_024)), [], state}
    end
  end

  defp abandon_actions(state) do
    case Codex.interrupt(state) do
      {:write, bytes} -> [{:write, bytes}, :close_stdin]
      :signal -> [:close_stdin]
    end
  end

  defp mcp_status(params, state) do
    name = params["name"]

    cond do
      not is_binary(name) ->
        {[], [], state}

      not MapSet.member?(state.allowed_servers, name) ->
        error =
          "unexpected MCP server #{name} loaded; Helmsman runs Codex only with its own MCP servers"

        actions = guard_actions(state)

        {Codex.warning(error), actions,
         %{state | fatal: error, closed?: state.closed? or actions == [:close_stdin]}}

      name == "helmsman" and params["status"] == "failed" ->
        {Codex.warning(
           "Helmsman MCP failed to start: " <> safe_error(params["error"] || "unknown", 1_024)
         ), [], state}

      true ->
        {[], [], state}
    end
  end

  defp guard_actions(%{closed?: true}), do: []

  defp guard_actions(state) do
    case Codex.interrupt(state) do
      {:write, bytes} -> [{:write, bytes}]
      :signal -> [:close_stdin]
    end
  end

  defp token_usage(%{"turnId" => id, "tokenUsage" => %{"last" => last}}, state)
       when is_binary(id) and is_map(last) do
    previous = Map.get(state.usage_by_turn, id, empty_usage())

    usage =
      Enum.reduce(
        [
          {"inputTokens", :input_tokens},
          {"outputTokens", :output_tokens},
          {"cachedInputTokens", :cache_read_tokens},
          {"cacheWriteInputTokens", :cache_write_tokens}
        ],
        previous,
        fn {key, field}, acc ->
          value = last[key]

          if is_integer(value) and value >= 0,
            do: Map.put(acc, field, (acc[field] || 0) + value),
            else: acc
        end
      )

    {[], [], %{state | usage_by_turn: Map.put(state.usage_by_turn, id, usage)}}
  end

  defp token_usage(_, state), do: {[], [], state}

  defp item("item/completed", %{"type" => "agentMessage", "text" => text}, state)
       when is_binary(text), do: {text_event(:text, text), [], %{state | text: text}}

  defp item("item/completed", %{"type" => "reasoning"} = item, state) do
    text = Enum.join(item["summary"] || [], "\n\n")
    text = if text == "", do: Enum.join(item["content"] || [], "\n\n"), else: text
    {text_event(:thinking, text), [], state}
  end

  defp item(method, %{"type" => type, "id" => id} = item, state) when type in @tools do
    call = if MapSet.member?(state.tools, id), do: [], else: [tool_call(item)]
    events = if method == "item/completed", do: call ++ [tool_result(item)], else: call
    {events, [], %{state | tools: MapSet.put(state.tools, id)}}
  end

  defp item(_, _, state), do: {[], [], state}
  defp text_event(_, ""), do: []
  defp text_event(type, text), do: [{type, %{text: safe(text, 32_768)}}]

  defp tool_call(item) do
    {name, input} =
      case item["type"] do
        "commandExecution" ->
          {"shell", item["command"] || ""}

        "fileChange" ->
          {"apply_patch",
           Enum.map_join(item["changes"] || [], "\n", fn change ->
             "#{change["kind"] |> kind()} #{change["path"]}"
           end)}

        "mcpToolCall" ->
          {"mcp__#{item["server"]}__#{item["tool"]}", JSON.encode!(item["arguments"])}

        "webSearch" ->
          {"web_search", item["query"] || ""}
      end

    {:tool_call, %{call_id: item["id"], name: name, input: safe(input, 2_048)}}
  end

  defp kind(%{"type" => type}), do: type
  defp kind(value) when is_binary(value), do: value
  defp kind(_), do: "change"

  defp tool_result(item) do
    {output, error?} = tool_output(item)
    {output, truncated?} = Event.truncate(output, 16_384)

    {:tool_result,
     %{call_id: item["id"], output: output, is_error: error?, truncated: truncated?}}
  end

  defp tool_output(%{"type" => "commandExecution"} = item),
    do:
      {item["aggregatedOutput"] || "",
       item["status"] != "completed" or item["exitCode"] not in [nil, 0]}

  defp tool_output(%{"type" => "fileChange"} = item),
    do: {item["status"] || "", item["status"] != "completed"}

  defp tool_output(%{"type" => "webSearch"} = item), do: {item["query"] || "", false}

  defp tool_output(item) do
    output = if item["error"], do: error_text(item["error"]), else: content_text(item["result"])
    {output, item["status"] == "failed" or not is_nil(item["error"])}
  end

  defp content_text(%{"content" => content}) when is_list(content),
    do: Enum.map_join(content, "\n", fn block -> block["text"] || "" end)

  defp content_text(_), do: ""

  defp server_request(id, method, params, state) do
    response =
      case method do
        method
        when method in [
               "item/commandExecution/requestApproval",
               "item/fileChange/requestApproval"
             ] ->
          %{"result" => %{"decision" => "acceptForSession"}}

        method when method in ["execCommandApproval", "applyPatchApproval"] ->
          %{"result" => %{"decision" => "approved_for_session"}}

        "item/permissions/requestApproval" ->
          %{"result" => %{"permissions" => params["permissions"] || %{}, "scope" => "session"}}

        "mcpServer/elicitation/request" ->
          %{"result" => %{"action" => "decline"}}

        _ ->
          %{
            "error" => %{
              "code" => -32_601,
              "message" => "Helmsman runs are unattended; ask questions with add_feedback"
            }
          }
      end

    actions = if state.closed?, do: [], else: [{:write, Codex.frame(Map.put(response, "id", id))}]
    {Codex.warning("Automatically answered Codex request #{method}"), actions, state}
  end

  def finish(code, state) do
    usage =
      if state.result,
        do: state.usage,
        else: Map.get(state.usage_by_turn, state.turn_id, empty_usage())

    {sanitize_result(finish_result(code, state)),
     %{session_id: state.session_id, summary: safe(state.text, 4_096), usage: usage}}
  end

  defp sanitize_result({:failed, reason, message}),
    do: {:failed, reason, safe_error(message, 8_192)}

  defp sanitize_result(:succeeded), do: :succeeded

  defp finish_result(_, %{abandoned: abandoned}) when not is_nil(abandoned), do: abandoned
  defp finish_result(_, %{fatal: fatal}) when is_binary(fatal), do: {:failed, :cli_error, fatal}
  defp finish_result(_, %{error: error}) when is_map(error), do: failure(error)

  defp finish_result(_, %{result: %{"status" => "interrupted"}}),
    do: {:failed, :cli_error, "turn interrupted"}

  defp finish_result(0, %{result: %{"status" => "completed"}}), do: :succeeded
  defp finish_result(0, _), do: {:failed, :cli_error, "exited before the turn completed"}

  defp finish_result(code, state),
    do:
      {:failed, :cli_error, "Codex exit #{code}: " <> safe(Enum.join(state.stderr, "\n"), 4_096)}

  defp failure(error) do
    reason = classify(error["codexErrorInfo"])
    reason = if context_error?(error), do: :context_overflow, else: reason
    message = error_text(error)

    message =
      if reason == :provider_auth,
        do:
          message <>
            "; Configure Codex for the Helmsman daemon in #{Config.home()} (codex login, or a model provider in config.toml)",
        else: message

    {:failed, reason, safe_error(message, 8_192)}
  end

  def classify("unauthorized"), do: :provider_auth
  def classify("usageLimitExceeded"), do: :provider_quota

  def classify(value) when value in ["rateLimitExceeded", "serverOverloaded"],
    do: :provider_rate_limit

  def classify("contextWindowExceeded"), do: :context_overflow

  def classify(value) when value in ["responseTooManyFailedAttempts", "internalServerError"],
    do: :provider_network

  def classify(value) when is_map(value) do
    Enum.find_value(value, :cli_error, &classify_status/1)
  end

  def classify(_), do: :cli_error

  defp classify_status({kind, detail})
       when kind in [
              "httpConnectionFailed",
              "responseStreamConnectionFailed",
              "responseStreamDisconnected",
              "responseTooManyFailedAttempts"
            ] and is_map(detail),
       do: http_failure(detail["httpStatusCode"])

  defp classify_status(_), do: nil

  defp http_failure(status) when status in [401, 403], do: :provider_auth
  defp http_failure(429), do: :provider_rate_limit
  defp http_failure(408), do: :provider_network

  defp http_failure(status) when is_integer(status) and status >= 400 and status < 500,
    do: :cli_error

  defp http_failure(_), do: :provider_network

  defp context_error?(error) do
    error["codexErrorInfo"] in ["other", "badRequest", nil] and
      Regex.match?(
        ~r/context_length_exceeded|exceeds the context window|maximum context length/i,
        error_text(error)
      )
  end

  defp error_text(error) when is_map(error),
    do:
      Enum.filter([error["message"], error["additionalDetails"]], &is_binary/1) |> Enum.join("\n")

  defp error_text(error) when is_binary(error), do: error
  defp error_text(_), do: "Codex error"

  defp empty_usage,
    do: %{
      input_tokens: nil,
      output_tokens: nil,
      cache_read_tokens: nil,
      cache_write_tokens: nil,
      cost_usd: nil
    }

  defp safe(text, limit) do
    text =
      if String.valid?(text), do: text, else: inspect(text, binaries: :as_binaries, limit: 50)

    elem(Event.truncate(text, limit), 0)
  end

  defp safe_error(text, limit) do
    text =
      if String.valid?(text), do: text, else: inspect(text, binaries: :as_binaries, limit: 50)

    text =
      Regex.replace(~r{https?://[^\s<>"\\]+}i, text, fn url ->
        uri = URI.parse(url)
        URI.to_string(%{uri | userinfo: nil, query: nil, fragment: nil})
      end)

    safe(text, limit)
  end
end
