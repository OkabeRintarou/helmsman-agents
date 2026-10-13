defmodule HelmsmanDaemon.Adapters.Copilot.Output do
  @moduledoc false
  alias HelmsmanDaemon.Adapters.Copilot.Failure
  alias HelmsmanProtocol.Event

  def init(spec, session_id) do
    %{
      spec: spec,
      session_id: session_id,
      emitted?: false,
      result: nil,
      error: nil,
      interrupted?: false,
      fatal: nil,
      text: "",
      stderr: [],
      snapshot: %{},
      usage: usage(%{}, %{}),
      allowed_servers: MapSet.new(["helmsman" | Map.keys(spec.agent.extra_mcp_servers)])
    }
  end

  def handle(:stderr, line, state),
    do: {[], [], %{state | stderr: Enum.take(state.stderr ++ [safe(line, 4_096)], -50)}}

  def handle(:stdout, line, state) do
    case JSON.decode(line) do
      {:ok, value} when is_map(value) ->
        events = if state.emitted?, do: [], else: [{:session, %{session_id: state.session_id}}]
        {next, actions, state} = output(value, %{state | emitted?: true})
        {events ++ next, actions, state}

      _ ->
        {warning("Invalid Copilot JSON: " <> safe(line, 200)), [], state}
    end
  end

  defp output(%{"type" => "assistant.message", "data" => %{"content" => text}}, state)
       when is_binary(text) and text != "",
       do: {[{:text, %{text: safe(text, 32_768)}}], [], %{state | text: text}}

  defp output(%{"type" => "assistant.reasoning", "data" => %{"content" => text}}, state)
       when is_binary(text) and text != "",
       do: {[{:thinking, %{text: safe(text, 32_768)}}], [], state}

  defp output(%{"type" => "tool.execution_start", "data" => data}, state) do
    event =
      {:tool_call,
       %{
         call_id: data["toolCallId"],
         name: data["toolName"],
         input: safe(JSON.encode!(data["arguments"] || %{}), 2_048)
       }}

    {[event], [], state}
  end

  defp output(%{"type" => "tool.execution_complete", "data" => data}, state) do
    text = get_in(data, ["result", "content"]) || ""
    text = if is_binary(text), do: text, else: JSON.encode!(text)
    {text, truncated?} = Event.truncate(text, 16_384)

    {[
       {:tool_result,
        %{
          call_id: data["toolCallId"],
          output: text,
          is_error: data["success"] != true,
          truncated: truncated?
        }}
     ], [], state}
  end

  defp output(%{"type" => "session.usage_checkpoint", "data" => data}, state),
    do: {[], [], %{state | snapshot: data["accountingSnapshot"] || %{}}}

  defp output(%{"type" => "result"} = result, state) do
    id = result["sessionId"] || state.session_id

    changed =
      if id != state.session_id,
        do: warning("Copilot returned a different session ID") ++ [{:session, %{session_id: id}}],
        else: []

    usage = usage(state.snapshot, result["usage"] || %{})

    success =
      result["exitCode"] == 0 and is_nil(state.error) and
        not state.interrupted? and is_nil(state.fatal)

    events =
      changed ++ [{:usage, usage}, {:result, %{text: safe(state.text, 32_768), success: success}}]

    {events, [], %{state | session_id: id, result: result, usage: usage}}
  end

  defp output(%{"type" => "session.warning", "data" => data}, state),
    do: {warning(data["message"] || "Copilot warning"), [], state}

  defp output(%{"type" => "session.error", "data" => error}, state),
    do: {[], [], %{state | error: error}}

  defp output(%{"type" => type}, state) when type in ["abort", "agent.interrupted"],
    do: {[], [], %{state | interrupted?: true}}

  defp output(%{"type" => "assistant.idle", "data" => %{"aborted" => true}}, state),
    do: {[], [], %{state | interrupted?: true}}

  defp output(%{"type" => "session.mcp_server_status_changed", "data" => data}, state),
    do: mcp(data, state)

  defp output(%{"type" => "session.mcp_servers_loaded", "data" => data}, state) do
    Enum.reduce(data["servers"] || [], {[], [], state}, fn server, {events, actions, state} ->
      {next, more, state} = mcp(server, state)
      {events ++ next, actions ++ more, state}
    end)
  end

  defp output(_, state), do: {[], [], state}

  defp mcp(data, state) do
    name = data["serverName"] || data["name"]

    cond do
      unexpected?(data["status"], name, state) ->
        message =
          "Copilot CLI connected an MCP server Helmsman did not configure: #{name} (#{source(data)})"

        actions = if state.fatal, do: [], else: [{:abort, :cli_error, message}]
        {warning(message), actions, %{state | fatal: state.fatal || message}}

      name == "helmsman" and data["status"] == "failed" ->
        {warning("Helmsman MCP is not connected"), [], state}

      true ->
        {[], [], state}
    end
  end

  defp source(data), do: data["configSource"] || data["source"] || "unknown"

  defp unexpected?(status, name, state),
    do: status == "connected" and not MapSet.member?(state.allowed_servers, name)

  def usage(snapshot, result) do
    fields = [
      {"inputTokens", :input_tokens},
      {"outputTokens", :output_tokens},
      {"cacheReadTokens", :cache_read_tokens},
      {"cacheWriteTokens", :cache_write_tokens},
      {"reasoningTokens", :reasoning_tokens}
    ]

    metrics = Map.values(snapshot["modelMetrics"] || %{})

    Enum.reduce(fields, %{cost_usd: nil, premium_requests: result["premiumRequests"]}, fn {key,
                                                                                           field},
                                                                                          acc ->
      values =
        for metric <- metrics,
            value = get_in(metric, ["usage", key]),
            is_integer(value) and value >= 0,
            do: value

      Map.put(acc, field, if(values == [], do: nil, else: Enum.sum(values)))
    end)
  end

  def finish(code, state) do
    result = finish_result(code, state)

    result =
      case result do
        {:failed, reason, message} -> {:failed, reason, safe(message, 8_192)}
        :succeeded -> :succeeded
      end

    {result,
     %{session_id: state.session_id, summary: safe(state.text, 4_096), usage: state.usage}}
  end

  defp finish_result(_, %{fatal: fatal}) when is_binary(fatal), do: {:failed, :cli_error, fatal}

  defp finish_result(_, %{interrupted?: true}),
    do: {:failed, :cli_error, "Copilot CLI was interrupted"}

  defp finish_result(_, %{error: error} = state) when is_map(error),
    do: Failure.session(error, state.spec)

  defp finish_result(0, %{result: %{"exitCode" => 0}}), do: :succeeded

  defp finish_result(0, %{result: nil}),
    do: {:failed, :cli_error, "Copilot CLI exited without a result"}

  defp finish_result(code, state) do
    fallback =
      case state.result do
        %{"exitCode" => 0} ->
          "Copilot CLI exited with status #{inspect(code)} after reporting success"

        %{"exitCode" => exit} ->
          "Copilot CLI reported exit code #{inspect(exit)}"

        _ ->
          "Copilot CLI exited with status #{inspect(code)}"
      end

    Failure.classify(Enum.join(state.stderr, "\n"), state.spec, fallback)
  end

  defp warning(text), do: [{:status, %{level: :warning, message: safe(text, 4_096)}}]

  defp safe(text, limit) do
    text = if String.valid?(text), do: text, else: inspect(text, binaries: :as_binaries)
    elem(Event.truncate(text, limit), 0)
  end
end
