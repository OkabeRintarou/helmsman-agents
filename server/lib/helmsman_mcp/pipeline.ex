defmodule HelmsmanMCP.Pipeline do
  @moduledoc """
  Runs a tool call (designs/08 §2): resolves the identity, calls the tool
  and turns its result into the text the agent sees. Independent of the
  MCP library.

    * `:read` tools run with the current identity in `scope.actor`
      (`HelmsmanMCP.Identity.current/2`);
    * `:write` tools run inside `Helmsman.Actors.with_writer/3`, as the
      `actor` / `author` argument, the session identity, the token's
      default agent or, on the session's first write, a new session agent,
      which then becomes the session identity. With a run token both run
      as the run's agent, whatever the arguments.

  A write tool may return `{:ok, %HelmsmanMCP.Rejected{reason: reason}}`:
  the write commits (and a new session agent is registered), then the
  call answers with the error text of `reason`.

  Success is the JSON of the value; a domain error is the text of
  `HelmsmanMCP.ErrorText`; anything unexpected is a generic text with a
  reference that the log repeats with the details.

  Every call of a registered tool logs one line (designs/11 §3,
  `add-release-distribution` decision 6) with the workspace, the identity
  name, the run (run tokens), the tool, the duration and the result class
  (`ok`, `error`, `internal`), never arguments or results, and emits
  `[:helmsman, :mcp, :tool_call]` (`duration`; `tool` and `result` only).
  """

  require Logger

  alias Helmsman.Accounts.Scope
  alias Helmsman.Actors
  alias Helmsman.Actors.Actor
  alias HelmsmanMCP.{Context, ErrorText, Identity, Rejected, Sessions, Tools}

  @writer_keys ["actor", "author"]

  @doc """
  Calls the tool `name`. Returns `{:ok, json}` or `{:error, text}`.
  """
  @spec call_tool(String.t(), map(), Scope.t(), String.t() | nil) ::
          {:ok, String.t()} | {:error, String.t()}
  def call_tool(name, args, %Scope{} = scope, session_id) when is_map(args) do
    case Tools.fetch(name) do
      {:ok, module} -> call_module(module, args, scope, session_id)
      :error -> {:error, "Unknown tool #{name}."}
    end
  end

  @doc """
  Calls the tool `module` as `call_tool/4` does (tests use it with tools
  that are not registered).
  """
  @spec call_module(module(), map(), Scope.t(), String.t() | nil) ::
          {:ok, String.t()} | {:error, String.t()}
  def call_module(module, args, %Scope{} = scope, session_id) when is_map(args) do
    ctx = %Context{
      tool: module.name(),
      args: stringify_keys(args),
      scope: scope,
      session: session(session_id)
    }

    run(module, ctx)
  end

  @doc """
  Runs `fun` on the read path of tools, for resources and prompts: the
  context of `name` and `args`, with the current identity in
  `scope.actor`. Returns `{:ok, value}`, or the reason and its text
  (`:internal` for an unexpected failure, logged with a reference).
  """
  @spec read(String.t(), map(), Scope.t(), String.t() | nil, (Context.t() -> term())) ::
          {:ok, term()} | {:error, term(), String.t()}
  def read(name, args, %Scope{} = scope, session_id, fun)
      when is_map(args) and is_function(fun, 1) do
    ctx = %Context{
      tool: name,
      args: stringify_keys(args),
      scope: scope,
      session: session(session_id)
    }

    try do
      case fun.(%{ctx | scope: %{scope | actor: Identity.current(scope, ctx.session)}}) do
        {:ok, value} ->
          {:ok, value}

        {:error, reason} ->
          case ErrorText.format(reason, ctx) do
            {:ok, text} -> {:error, reason, text}
            :error -> read_failure(ctx, "unexpected error: " <> inspect(reason))
          end
      end
    catch
      kind, reason -> read_failure(ctx, Exception.format(kind, reason, __STACKTRACE__))
    end
  end

  defp read_failure(ctx, details) do
    {:error, text} = internal_error(ctx, details)
    {:error, :internal, text}
  end

  defp run(module, ctx) do
    started = System.monotonic_time()
    {class, result, actor} = call(module, ctx)
    log_call(ctx, actor, class, System.monotonic_time() - started)
    result
  end

  # Returns the result class, the result and the identity it ran as.
  defp call(module, ctx) do
    {outcome, actor} = execute(module.mode(), module, ctx)
    {class, result} = to_text(outcome, ctx)
    {class, result, actor}
  catch
    kind, reason ->
      {:internal, internal_error(ctx, Exception.format(kind, reason, __STACKTRACE__)), nil}
  end

  defp log_call(ctx, actor, class, duration) do
    duration_ms = System.convert_time_unit(duration, :native, :millisecond)
    scope = ctx.scope

    metadata =
      Enum.reject(
        [
          workspace_id: scope.workspace && scope.workspace.id,
          actor: identity_name(actor || scope.actor),
          run_id: scope.run && scope.run.id,
          mcp_tool: ctx.tool,
          duration_ms: duration_ms,
          result: class
        ],
        fn {_key, value} -> is_nil(value) end
      )

    Logger.info(
      "mcp tool call tool=#{ctx.tool} result=#{class} duration_ms=#{duration_ms}",
      metadata
    )

    :telemetry.execute([:helmsman, :mcp, :tool_call], %{duration: duration}, %{
      tool: ctx.tool,
      result: class
    })
  end

  defp identity_name(%Actor{name: name}), do: name
  defp identity_name(_actor), do: nil

  defp execute(:read, module, ctx) do
    scope = %{ctx.scope | actor: Identity.current(ctx.scope, ctx.session)}
    {module.call(ctx.args, %{ctx | scope: scope}), scope.actor}
  end

  defp execute(:write, module, ctx) do
    {requested, args} = pop_writer(ctx.args)

    opts = [
      requested: requested,
      session_actor_id: ctx.session && ctx.session.actor_id,
      auto_agent: true
    ]

    case Actors.with_writer(ctx.scope, opts, &module.call(args, %{ctx | scope: &1})) do
      {:ok, value, %{actor: actor, source: :auto}} ->
        Identity.put(ctx.session, actor, :auto)
        {committed(value), actor}

      {:ok, value, %{actor: actor}} ->
        {committed(value), actor}

      {:error, _reason} = error ->
        {error, nil}
    end
  end

  # After the commit: a business refusal is shown as an error.
  defp committed(%Rejected{reason: reason}), do: {:error, reason}
  defp committed(value), do: {:ok, value}

  defp pop_writer(args) do
    requested = Enum.find_value(@writer_keys, &args[&1])
    {requested, Map.drop(args, @writer_keys)}
  end

  defp to_text({:ok, value}, _ctx), do: {:ok, {:ok, Jason.encode!(value)}}

  defp to_text({:error, reason}, ctx) do
    case ErrorText.format(reason, ctx) do
      {:ok, text} -> {:error, {:error, text}}
      :error -> {:internal, internal_error(ctx, "unexpected error: " <> inspect(reason))}
    end
  end

  defp internal_error(ctx, details) do
    ref = 4 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)
    Logger.error("MCP tool #{ctx.tool} failed (ref #{ref}): " <> details)
    {:error, ErrorText.internal(ref)}
  end

  defp session(session_id) do
    case Sessions.lookup(session_id) do
      %{actor_id: actor_id, source: source} ->
        %{id: session_id, actor_id: actor_id, source: source}

      nil ->
        nil
    end
  end

  defp stringify_keys(map), do: Map.new(map, fn {key, value} -> {to_string(key), value} end)
end
