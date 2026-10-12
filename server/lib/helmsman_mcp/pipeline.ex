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
      which then becomes the session identity.

  Success is the JSON of the value; a domain error is the text of
  `HelmsmanMCP.ErrorText`; anything unexpected is a generic text with a
  reference that the log repeats with the details.
  """

  require Logger

  alias Helmsman.Accounts.Scope
  alias Helmsman.Actors
  alias HelmsmanMCP.{Context, ErrorText, Identity, Sessions, Tools}

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
    module.mode()
    |> execute(module, ctx)
    |> to_text(ctx)
  catch
    kind, reason -> internal_error(ctx, Exception.format(kind, reason, __STACKTRACE__))
  end

  defp execute(:read, module, ctx) do
    scope = %{ctx.scope | actor: Identity.current(ctx.scope, ctx.session)}
    module.call(ctx.args, %{ctx | scope: scope})
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
        {:ok, value}

      {:ok, value, _writer} ->
        {:ok, value}

      {:error, _reason} = error ->
        error
    end
  end

  defp pop_writer(args) do
    requested = Enum.find_value(@writer_keys, &args[&1])
    {requested, Map.drop(args, @writer_keys)}
  end

  defp to_text({:ok, value}, _ctx), do: {:ok, Jason.encode!(value)}

  defp to_text({:error, reason}, ctx) do
    case ErrorText.format(reason, ctx) do
      {:ok, text} -> {:error, text}
      :error -> internal_error(ctx, "unexpected error: " <> inspect(reason))
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
