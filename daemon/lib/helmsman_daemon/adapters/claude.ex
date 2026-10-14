defmodule HelmsmanDaemon.Adapters.Claude do
  @moduledoc """
  Claude Code stream JSON launch, event normalization and failure classification.

  Steering (`add-run-steering` decision 12; live test S1–S4 in
  `reviews/impl-notes-1.md`, Claude 实测): with `--replay-user-messages`
  the CLI echoes each user message (`isReplay: true`) when it takes it into
  the session, whether into the current turn or as a new one, and the next
  `result` answers every message echoed before it. A steering message is
  delivered at its echo, compared in full with the earliest one still
  waiting. stdin is closed at a `result` only when no steering message
  still waits for its echo (or the result is an error). An echoed message
  stays unanswered until the next `result`; exiting with a message not
  echoed or not answered yet is a failure, whatever an earlier result said.
  """
  @behaviour HelmsmanDaemon.Adapter
  require Logger
  alias HelmsmanDaemon.Adapters.Claude.{Provider, Vendor}
  alias HelmsmanDaemon.{Exec, Launch}
  alias HelmsmanProtocol.Event

  @minimum Version.parse!("2.1.0")
  @efforts ~w(low medium high xhigh max)
  @models ~w(fable opus sonnet)
  @valued ~w(--output-format --input-format --permission-mode --session-id --setting-sources --model --effort)
  @optional ~w(--resume -r)
  @switches ~w(-p --print --verbose --dangerously-skip-permissions --strict-mcp-config --continue -c --include-partial-messages --replay-user-messages --no-session-persistence --fork-session)
  @failures [
    {~r/Not logged in|Please run \/login|Invalid API key/i, :provider_auth},
    {~r/Credit balance is too low/i, :provider_quota},
    {~r/Too many requests/i, :provider_rate_limit},
    {~r/Connection refused.*ConnectionRefused/i, :provider_network},
    {~r/Prompt is too long/i, :context_overflow}
  ]

  def vendor, do: Vendor.infer()

  def provider, do: :claude
  def executable, do: "claude"
  def min_version, do: @minimum
  def detect, do: detect(&Exec.version/1, fn -> HelmsmanDaemon.Env.cmd("id", ["-u"]) end)

  @doc false
  def detect(version_probe, uid_probe) do
    case uid_probe.() do
      {uid, 0} when is_binary(uid) ->
        if String.trim(uid) == "0",
          do:
            {:error,
             "Claude Code refuses to skip permission prompts as root; run the daemon as a normal user"},
          else: detect_version(version_probe)

      _ ->
        {:error, "Could not determine effective user ID"}
    end
  end

  defp detect_version(probe) do
    with {:ok, output} <- probe.(executable()),
         [_, version] <- Regex.run(~r/^(\d+\.\d+\.\d+)/, output),
         {:ok, parsed} <- Version.parse(version) do
      if Version.compare(parsed, @minimum) == :lt,
        do: {:error, "CLI version too old; requires #{@minimum}"},
        else: {:ok, %{version: version, models: @models, efforts: @efforts}}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, "Invalid Claude Code version"}
    end
  end

  # `update-claude-setting-sources`: only user-level settings load, so the
  # repository's `.claude/settings*.json` cannot redirect requests or
  # credentials; its CLAUDE.md still loads through the additional directory.
  @claude_md_env {"CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD", "1"}

  def prepare(spec, run_dir, work_dir) do
    path = Path.join(run_dir, "mcp.json")
    extra = spec.agent.extra_mcp_servers

    config = %{
      "mcpServers" =>
        Map.put(Map.delete(extra, "helmsman"), "helmsman", %{
          "type" => "http",
          "url" => spec.mcp.url,
          "headers" => %{"Authorization" => "Bearer ${HELMSMAN_RUN_TOKEN}"}
        })
    }

    {args, provider_removed} = provider_args(spec.agent.custom_args, spec.agent.provider_account)
    {custom, removed} = filter_args(args, [], [])
    removed = removed ++ provider_removed

    events =
      if Map.has_key?(extra, "helmsman"),
        do: warning("Ignored extra MCP server named helmsman"),
        else: []

    events =
      if removed == [],
        do: events,
        else:
          events ++
            warning(
              "Ignored conflicting Claude arguments: " <> Enum.join(Enum.uniq(removed), ", ")
            )

    with :ok <- File.write(path, JSON.encode!(config)),
         :ok <- File.chmod(path, 0o600),
         {:ok, provider_args, env, provider_events} <- Provider.prepare(spec.agent, run_dir) do
      {:ok,
       %Launch{
         argv:
           [
             System.find_executable(executable()) || executable(),
             "-p",
             "--input-format",
             "stream-json",
             "--output-format",
             "stream-json",
             "--verbose",
             "--replay-user-messages",
             "--permission-mode",
             "bypassPermissions",
             "--strict-mcp-config",
             "--mcp-config",
             path,
             "--setting-sources",
             "user",
             # `=`: `--add-dir` takes several values and would swallow the next one.
             "--add-dir=" <> work_dir
           ] ++
             provider_args ++
             option("--model", spec.agent.model) ++
             option("--effort", spec.agent.effort) ++
             option("--resume", spec.resume_session_id) ++ custom,
         stdin: frame(spec.prompt),
         close_stdin?: false,
         env: [@claude_md_env | env],
         events: events ++ provider_events
       }}
    else
      {:error, reason} ->
        {:error, {:workspace_prepare, "Could not write private Claude MCP config: #{reason}"}}
    end
  end

  defp provider_args(args, nil), do: {args, []}
  defp provider_args(args, _account), do: filter_provider_args(args, [], [])

  defp filter_provider_args([], kept, removed), do: {Enum.reverse(kept), Enum.reverse(removed)}

  defp filter_provider_args([arg | rest], kept, removed) do
    flag = arg |> String.split("=", parts: 2) |> hd()

    if flag == "--settings" do
      rest = if String.contains?(arg, "="), do: rest, else: drop_value(rest)
      filter_provider_args(rest, kept, [flag | removed])
    else
      filter_provider_args(rest, [arg | kept], removed)
    end
  end

  defp option(_flag, value) when value in [nil, ""], do: []
  defp option(flag, value), do: [flag, value]

  defp frame(text),
    do:
      JSON.encode!(%{
        "type" => "user",
        "message" => %{"role" => "user", "content" => [%{"type" => "text", "text" => text}]}
      }) <> "\n"

  defp filter_args([], kept, removed), do: {Enum.reverse(kept), Enum.reverse(removed)}

  defp filter_args([arg | rest], kept, removed) do
    flag = arg |> String.split("=", parts: 2) |> hd()
    equals? = String.contains?(arg, "=")

    cond do
      flag == "--mcp-config" ->
        filter_args(Enum.drop_while(rest, &(not String.starts_with?(&1, "-"))), kept, [
          flag | removed
        ])

      flag in @valued ->
        filter_args(if(equals?, do: rest, else: drop_value(rest)), kept, [flag | removed])

      flag in @optional ->
        filter_args(if(equals?, do: rest, else: drop_value(rest)), kept, [flag | removed])

      flag in @switches ->
        filter_args(rest, kept, [flag | removed])

      true ->
        filter_args(rest, [arg | kept], removed)
    end
  end

  defp drop_value([value | rest]),
    do: if(String.starts_with?(value, "-"), do: [value | rest], else: rest)

  defp drop_value([]), do: []

  def init_state(spec),
    do: %{
      provider_account?: provider_account?(spec),
      aborted?: false,
      session_id: nil,
      result: nil,
      usage: nil,
      stderr: [],
      diagnostics: MapSet.new(),
      closed?: false,
      prompt: prompt(spec),
      prompt_echoed?: false,
      steers: [],
      unanswered?: false
    }

  defp prompt(%{prompt: prompt}) when is_binary(prompt), do: prompt
  defp prompt(_spec), do: nil

  defp provider_account?(%{agent: %{provider_account: account}}), do: not is_nil(account)
  defp provider_account?(_spec), do: false

  def handle_output(_stream, _line, %{aborted?: true} = state), do: {[], [], state}

  def handle_output(:stderr, line, state) do
    {events, state} = diagnostic(line, state)
    {events, [], %{state | stderr: Enum.take(state.stderr ++ [safe(line, 4_096)], -50)}}
  end

  def handle_output(:stdout, line, state) do
    case JSON.decode(line) do
      {:ok, value} when is_map(value) -> output(value, state)
      _ -> {warning("Invalid Claude JSON: " <> safe(line, 200)), [], state}
    end
  end

  defp diagnostic(line, state) do
    case Regex.run(~r/^\[claude-code:([^\]]+)\]/, line) do
      [_, tag] ->
        if MapSet.member?(state.diagnostics, tag) do
          {[], state}
        else
          {warning(safe("Claude diagnostic: " <> line, 1_024)),
           %{state | diagnostics: MapSet.put(state.diagnostics, tag)}}
        end

      _ ->
        {[], state}
    end
  end

  defp output(
         %{"type" => "system", "subtype" => "init"} = value,
         %{provider_account?: true} = state
       )
       when not is_map_key(value, "apiKeySource") or
              :erlang.map_get("apiKeySource", value) != "apiKeyHelper" do
    source =
      if is_binary(value["apiKeySource"]), do: safe(value["apiKeySource"], 128), else: "unknown"

    message =
      "Claude Code used credentials from " <>
        source <>
        " instead of the provider account; stopped so that usage is not billed to another account (check managed settings, or Claude Code changed its settings format)"

    {[], [{:abort, :cli_error, message}], %{state | aborted?: true}}
  end

  defp output(%{"type" => "system", "subtype" => "init", "session_id" => id} = value, state)
       when is_binary(id) do
    servers = if is_list(value["mcp_servers"]), do: value["mcp_servers"], else: []

    warnings =
      if Enum.any?(servers, fn
           %{"name" => "helmsman", "status" => status} -> status != "connected"
           %{"name" => "helmsman"} -> true
           _ -> false
         end),
         do: warning("Helmsman MCP is not connected"),
         else: []

    {[{:session, %{session_id: id}}] ++ warnings, [], %{state | session_id: id}}
  end

  defp output(%{"type" => "assistant", "message" => %{"content" => content}}, state)
       when is_list(content),
       do: {Enum.flat_map(content, &assistant_block/1), [], state}

  defp output(
         %{"type" => "user", "isReplay" => true, "message" => %{"content" => content}},
         state
       ),
       do: echoed(content_text(content), state)

  defp output(%{"type" => "user", "message" => %{"content" => content}}, state)
       when is_list(content),
       do: {Enum.flat_map(content, &user_block/1), [], state}

  defp output(%{"type" => "result"} = value, state) do
    text = result_text(value)
    usage = usage(value)

    events = [
      {:usage, usage},
      {:result, %{text: safe(text, 32_768), success: value["is_error"] === false}}
    ]

    # Every message echoed so far is answered; one still waiting for its
    # echo will get a turn of its own (live test S2, S3).
    close? = state.steers == [] or value["is_error"] !== false

    {events, if(close?, do: [:close_stdin], else: []),
     %{
       state
       | result: value,
         session_id: value["session_id"] || state.session_id,
         usage: add_usage(state.usage, usage),
         closed?: close?,
         unanswered?: false
     }}
  end

  defp output(_value, state), do: {[], [], state}

  defp assistant_block(%{"type" => "text", "text" => text}) when is_binary(text),
    do: [{:text, %{text: safe(text, 32_768)}}]

  defp assistant_block(%{"type" => "thinking", "thinking" => text}) when is_binary(text),
    do: [{:thinking, %{text: safe(text, 32_768)}}]

  defp assistant_block(%{"type" => "tool_use", "name" => name} = block) when is_binary(name),
    do: [
      {:tool_call,
       %{
         call_id: optional_id(block["id"]),
         name: name,
         input: safe(JSON.encode!(block["input"]), 2_048)
       }}
    ]

  defp assistant_block(_), do: []

  defp user_block(%{"type" => "tool_result"} = block) do
    {output, truncated?} = Event.truncate(content_text(block["content"]), 16_384)

    [
      {:tool_result,
       %{
         call_id: optional_id(block["tool_use_id"]),
         output: output,
         is_error: block["is_error"] === true,
         truncated: truncated?
       }}
    ]
  end

  defp user_block(_), do: []
  defp optional_id(id) when is_binary(id), do: id
  defp optional_id(_), do: nil
  defp content_text(text) when is_binary(text), do: text

  defp content_text(blocks) when is_list(blocks) do
    blocks
    |> Enum.flat_map(fn
      %{"type" => "text", "text" => text} when is_binary(text) -> [text]
      _ -> []
    end)
    |> Enum.join("\n")
  end

  defp content_text(_), do: ""

  defp usage(value) do
    raw = if is_map(value["usage"]), do: value["usage"], else: %{}

    %{
      input_tokens: count(raw["input_tokens"]),
      output_tokens: count(raw["output_tokens"]),
      cache_read_tokens: count(raw["cache_read_input_tokens"]),
      cache_write_tokens: count(raw["cache_creation_input_tokens"]),
      cost_usd:
        if(is_number(value["total_cost_usd"]) and value["total_cost_usd"] >= 0,
          do: value["total_cost_usd"],
          else: nil
        )
    }
  end

  # Token counts are per result; `total_cost_usd` is the session's so far.
  defp add_usage(nil, usage), do: usage

  defp add_usage(total, usage) do
    Map.new(usage, fn
      {:cost_usd, cost} -> {:cost_usd, cost || total.cost_usd}
      {key, nil} -> {key, total[key]}
      {key, value} -> {key, (total[key] || 0) + value}
    end)
  end

  defp count(value) when is_integer(value) and value >= 0, do: value
  defp count(_), do: nil

  defp result_text(value) do
    errors = if is_list(value["errors"]), do: Enum.filter(value["errors"], &is_binary/1), else: []
    Enum.join(Enum.filter([value["result"] | errors], &is_binary/1), "\n")
  end

  def finish(code, state) do
    text = if state.result, do: result_text(state.result), else: ""

    error =
      Enum.join(
        [
          text,
          if(state.result && is_binary(state.result["terminal_reason"]),
            do: state.result["terminal_reason"],
            else: ""
          ),
          Enum.join(state.stderr, "\n")
        ],
        "\n"
      )

    result = outcome(code, state, error)
    {result, %{session_id: state.session_id, summary: safe(text, 4_096), usage: state.usage}}
  end

  defp outcome(code, state, error) do
    cond do
      clean_success?(code, state) and state.steers == [] and not state.unanswered? ->
        :succeeded

      clean_success?(code, state) ->
        {:failed, :cli_error,
         "Claude exited before answering every steering message (exit 0); " <>
           "the last result does not cover them"}

      is_nil(state.result) ->
        {:failed, missing_result_reason(code, error),
         "Claude exited without result (exit #{code}): " <> safe(error, 4_096)}

      true ->
        {:failed, classify(error), "Claude exit #{code}: " <> safe(error, 4_096)}
    end
  end

  defp clean_success?(0, %{result: %{"is_error" => false}}), do: true
  defp clean_success?(_code, _state), do: false

  defp missing_result_reason(0, _error), do: :cli_error
  defp missing_result_reason(_code, error), do: classify(error)

  defp classify(text),
    do:
      Enum.find_value(@failures, :cli_error, fn {regex, reason} ->
        if Regex.match?(regex, text), do: reason
      end)

  def interrupt(_state), do: :signal
  def steer(_ref, _text, %{closed?: true}), do: :unsupported

  def steer(ref, text, state),
    do: {:ok, frame(text), :pending, %{state | steers: state.steers ++ [{ref, text}]}}

  # `add-run-steering` decision 12: the prompt's own echo is not a steering
  # message; any other echo is compared, in full, with the earliest message
  # still waiting. No match: no receipt (the fallback stays).
  defp echoed(text, %{prompt_echoed?: false, prompt: text} = state),
    do: {[], [], %{state | prompt_echoed?: true}}

  defp echoed(text, %{steers: [{ref, text} | rest]} = state) do
    {[{:status, %{level: :info, message: "steer delivered"}}], [{:steer_result, ref, :delivered}],
     %{state | steers: rest, unanswered?: true}}
  end

  defp echoed(_text, state) do
    Logger.debug("Claude echoed a message that is not the next steering message")
    {[], [], state}
  end

  defp warning(message), do: [{:status, %{level: :warning, message: message}}]

  defp safe(text, limit) do
    text =
      if String.valid?(text), do: text, else: inspect(text, binaries: :as_binaries, limit: 50)

    elem(Event.truncate(text, limit), 0)
  end
end
