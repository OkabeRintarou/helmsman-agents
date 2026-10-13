defmodule HelmsmanDaemon.Adapters.Cursor.Output do
  @moduledoc """
  `cursor-agent -p --output-format stream-json` normalization, the MCP guard
  and failure classification (`add-cursor-adapter` decisions 7 and 9).
  Errors never come as events: the CLI exits 1 with the message on stderr.
  """
  alias HelmsmanProtocol.Event

  @failures [
    {~r/Authentication required|API key is invalid|NOT_LOGGED_IN|AUTH_TOKEN_EXPIRED|UNAUTHORIZED|BAD_API_KEY/i,
     :provider_auth},
    {~r/USAGE_LIMIT|usage limit|RESOURCE_EXHAUSTED|USAGE_PRICING_REQUIRED/i, :provider_quota},
    {~r/RATE_LIMIT|rate limit/i, :provider_rate_limit},
    {~r/CONVERSATION_TOO_LONG|MAX_TOKENS|too long/i, :context_overflow},
    {~r/Failed to reach the Cursor API|ECONNRESET|ECONNREFUSED|ETIMEDOUT|socket hang up|NGHTTP2/i,
     :provider_network},
    {~r/Cannot use this model/i, :model},
    {~r/Failed to claim persistent session/i, :session}
  ]

  def init(spec, session_id) do
    extra = spec.agent.extra_mcp_servers || %{}

    %{
      aborted?: false,
      session_id: session_id,
      model: spec.agent.model || "auto",
      servers: MapSet.new(["helmsman" | Map.keys(Map.delete(extra, "helmsman"))]),
      thinking: "",
      summary: nil,
      result: nil,
      usage: nil,
      stderr: []
    }
  end

  def handle(_stream, _line, %{aborted?: true} = state), do: {[], [], state}

  def handle(:stderr, line, state),
    do: {[], [], %{state | stderr: Enum.take(state.stderr ++ [safe(line, 4_096)], -50)}}

  def handle(:stdout, line, state) do
    case JSON.decode(line) do
      {:ok, value} when is_map(value) ->
        output(value, state)

      _ ->
        if String.trim(line) == "",
          do: {[], [], state},
          else: {warning("Invalid Cursor JSON: " <> safe(line, 200)), [], state}
    end
  end

  defp output(%{"type" => "system", "subtype" => "init"} = value, state) do
    if value["apiKeySource"] == "env" do
      id = if is_binary(value["session_id"]), do: value["session_id"], else: state.session_id
      {[{:session, %{session_id: id}}], [], %{state | session_id: id}}
    else
      abort(state, "Cursor did not use CURSOR_API_KEY")
    end
  end

  defp output(%{"type" => "assistant", "message" => %{"content" => content}} = value, state)
       when is_list(content) do
    texts =
      for %{"type" => "text", "text" => text} when is_binary(text) <- content, do: text

    text = Enum.join(texts)
    events = if text == "", do: [], else: [{:text, %{text: safe(text, 32_768)}}]

    summary =
      if is_nil(value["model_call_id"]) and text != "", do: text, else: state.summary

    {events, [], %{state | summary: summary}}
  end

  defp output(%{"type" => "thinking", "subtype" => "delta", "text" => text}, state)
       when is_binary(text),
       do: {[], [], %{state | thinking: state.thinking <> text}}

  defp output(%{"type" => "thinking", "subtype" => "completed"}, state) do
    events =
      if state.thinking == "", do: [], else: [{:thinking, %{text: safe(state.thinking, 32_768)}}]

    {events, [], %{state | thinking: ""}}
  end

  defp output(%{"type" => "tool_call", "subtype" => subtype} = value, state)
       when subtype in ["started", "completed"] do
    case tool(value["tool_call"]) do
      {kind, call} -> tool_call(subtype, call_id(value["call_id"]), kind, call, state)
      nil -> {[], [], state}
    end
  end

  defp output(%{"type" => "result"} = value, state) do
    text = if is_binary(value["result"]), do: value["result"], else: ""
    usage = usage(value["usage"])

    events = [
      {:usage, usage},
      {:result, %{text: safe(text, 32_768), success: value["is_error"] === false}}
    ]

    {events, [], %{state | result: value, usage: usage}}
  end

  defp output(%{"type" => "connection", "subtype" => "reconnecting"} = value, state),
    do: {info("Cursor is reconnecting" <> attempt(value)), [], state}

  defp output(%{"type" => "retry", "subtype" => "starting"} = value, state),
    do: {info("Cursor is retrying the request" <> attempt(value)), [], state}

  defp output(_value, state), do: {[], [], state}

  defp attempt(%{"attempt" => n}) when is_integer(n), do: " (attempt #{n})"
  defp attempt(_), do: ""

  defp tool(%{} = tool_call) do
    Enum.find_value(tool_call, fn
      {key, %{} = call} -> if String.ends_with?(key, "ToolCall"), do: {key, call}
      _ -> nil
    end)
  end

  defp tool(_), do: nil

  # The CLI's call IDs carry a literal newline between their two parts.
  defp call_id(id) when is_binary(id), do: id |> String.trim() |> String.replace(~r/\s+/, "")
  defp call_id(_), do: nil

  defp tool_call(subtype, id, "mcpToolCall", call, state) do
    args = if is_map(call["args"]), do: call["args"], else: %{}
    server = args["providerIdentifier"] || args["serverIdentifier"]

    if is_binary(server) and not MapSet.member?(state.servers, server) do
      abort(state, "Cursor used an MCP server Helmsman did not configure: " <> safe(server, 200))
    else
      name = if is_binary(args["name"]), do: args["name"], else: "mcp"
      tool_event(subtype, id, name, call, server == "helmsman", state)
    end
  end

  defp tool_call(subtype, id, kind, call, state),
    do: tool_event(subtype, id, tool_name(kind), call, false, state)

  defp tool_event("started", id, name, call, _helmsman?, state) do
    {[{:tool_call, %{call_id: id, name: name, input: safe(input(name, call["args"]), 2_048)}}],
     [], state}
  end

  defp tool_event("completed", id, name, call, helmsman?, state) do
    {output, error} = result(call["result"])
    {output, truncated?} = Event.truncate(valid(output), 16_384)
    event = {:tool_result, %{call_id: id, output: output, is_error: error, truncated: truncated?}}

    warnings =
      if helmsman? and error,
        do:
          warning(
            "Cursor rejected the Helmsman tool #{name} (the repository's hooks or permissions may block it): " <>
              safe(output, 1_024)
          ),
        else: []

    {[event | warnings], [], state}
  end

  defp tool_name("shellToolCall"), do: "shell"
  defp tool_name("editToolCall"), do: "edit"
  defp tool_name("readToolCall"), do: "read"
  defp tool_name(kind), do: String.replace_suffix(kind, "ToolCall", "")

  defp input("shell", %{"command" => command}) when is_binary(command), do: command
  defp input(name, %{"path" => path}) when name in ["edit", "read"] and is_binary(path), do: path
  defp input(_name, %{"args" => args, "providerIdentifier" => _}), do: JSON.encode!(args)
  defp input(_name, args) when is_map(args), do: JSON.encode!(Map.delete(args, "toolCallId"))
  defp input(_name, _args), do: ""

  defp result(%{"success" => success}) when is_map(success) do
    text =
      cond do
        is_binary(success["stdout"]) or is_binary(success["stderr"]) ->
          Enum.join(
            Enum.filter([success["stdout"], success["stderr"]], &(is_binary(&1) and &1 != "")),
            "\n"
          )

        is_list(success["content"]) ->
          content_text(success["content"])

        is_binary(success["content"]) ->
          success["content"]

        is_binary(success["message"]) ->
          success["message"]

        true ->
          JSON.encode!(success)
      end

    {text, success["isError"] === true}
  end

  defp result(%{"rejected" => rejected}) when is_map(rejected),
    do: {reason(rejected["reason"], "rejected"), true}

  defp result(%{"permissionDenied" => denied}) when is_map(denied),
    do: {reason(denied["error"], "permission denied"), true}

  defp result(%{} = other) when map_size(other) > 0, do: {JSON.encode!(other), true}
  defp result(_), do: {"", true}

  defp reason(text, _fallback) when is_binary(text) and text != "", do: text
  defp reason(_text, fallback), do: fallback

  defp content_text(blocks) do
    blocks
    |> Enum.flat_map(fn
      %{"text" => %{"text" => text}} when is_binary(text) -> [text]
      %{"text" => text} when is_binary(text) -> [text]
      _ -> []
    end)
    |> Enum.join("\n")
  end

  defp usage(raw) do
    raw = if is_map(raw), do: raw, else: %{}

    %{
      input_tokens: count(raw["inputTokens"]),
      output_tokens: count(raw["outputTokens"]),
      cache_read_tokens: count(raw["cacheReadTokens"]),
      cache_write_tokens: count(raw["cacheWriteTokens"]),
      cost_usd: nil
    }
  end

  defp count(value) when is_integer(value) and value >= 0, do: value
  defp count(_), do: nil

  @doc "Decision 9. A run the daemon stopped is decided by the daemon's reason."
  def finish(code, state) do
    summary =
      cond do
        is_binary(state.summary) -> state.summary
        state.result && is_binary(state.result["result"]) -> state.result["result"]
        true -> nil
      end

    metadata = %{
      session_id: state.session_id,
      summary: summary && safe(summary, 4_096),
      usage: state.usage
    }

    {outcome(code, state), metadata}
  end

  defp outcome(0, %{result: %{"is_error" => false}}), do: :succeeded

  defp outcome(_code, %{result: %{"is_error" => true} = result}),
    do: {:failed, :cli_error, safe(text(result["result"], "Cursor reported an error"), 4_096)}

  defp outcome(0, _state),
    do: {:failed, :cli_error, "Cursor exited without a result (exit 0)"}

  defp outcome(code, state) do
    stderr = Enum.join(state.stderr, "\n")
    tail = state.stderr |> Enum.take(-5) |> Enum.join("\n")

    case classify(stderr) do
      :model ->
        {:failed, :cli_error, "model #{state.model} is not available to this Cursor account"}

      :session ->
        {:failed, :cli_error,
         "the Cursor session can no longer be resumed: " <> safe(tail, 2_048)}

      reason ->
        {:failed, reason, safe("Cursor exit #{code}: " <> tail, 4_096)}
    end
  end

  @doc "Failure reason for the CLI's error text."
  def classify(text) do
    Enum.find_value(@failures, :cli_error, fn {regex, reason} ->
      if Regex.match?(regex, text), do: reason
    end)
  end

  defp text(value, _fallback) when is_binary(value) and value != "", do: value
  defp text(_value, fallback), do: fallback

  defp abort(state, message),
    do: {[], [{:abort, :cli_error, message}], %{state | aborted?: true}}

  defp warning(message), do: [{:status, %{level: :warning, message: safe(message, 4_096)}}]
  defp info(message), do: [{:status, %{level: :info, message: message}}]

  defp valid(text) when is_binary(text) do
    if String.valid?(text), do: text, else: inspect(text, binaries: :as_binaries, limit: 50)
  end

  defp safe(text, limit), do: elem(Event.truncate(valid(text), limit), 0)
end
