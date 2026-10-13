defmodule HelmsmanWeb.API.ToolAction do
  @moduledoc """
  REST as another transport of the MCP tools (`add-rest-api` decision 2).

  An endpoint names its tool and how path parameters become tool
  arguments; `run/3` then:

    1. builds the arguments (`HelmsmanWeb.API.Params`: query string or
       JSON body, path parameters on top, checked against the tool's
       schema);
    2. a `:read` tool runs with the request's current identity in
       `scope.actor` (`Helmsman.Actors.resolve_reader/2`);
    3. a `:write` tool runs inside `Helmsman.Actors.with_writer/3`
       (`auto_agent: false`: REST never creates session agents); a
       `%HelmsmanMCP.Rejected{}` result has committed and answers with
       its reason;
    4. `{:ok, value}` is `{"data": value}` (the JSON MCP returns);
       `{:error, reason}` goes through `HelmsmanWeb.ErrorMapper`; an
       exception is a 500 with a logged reference.

  ## Options

    * `:path` - `[argument: spec]`: the argument from the path parameter
      `"name"`, `{:integer, "name"}` for one that must be a positive
      integer (else 404; also implied by an `:integer` argument), or
      `{:feedback_id, "id", "seq"}` for `KEY-N#M`
    * `:drop` - arguments of the tool this endpoint never takes from the
      request (`POST /filters` creates, so it drops `filter_id`)
    * `:status` - the success status (default 200)
  """

  import Plug.Conn

  alias Helmsman.Accounts.Scope
  alias Helmsman.Actors
  alias HelmsmanMCP.{Context, Rejected}
  alias HelmsmanWeb.API.Params
  alias HelmsmanWeb.ErrorMapper

  @type path_spec ::
          String.t() | {:integer, String.t()} | {:feedback_id, String.t(), String.t()}
  @type opts :: [path: [{atom(), path_spec()}], drop: [atom()], status: pos_integer()]

  @doc "Runs the tool `tool` for `conn` (see the module doc)."
  @spec run(Plug.Conn.t(), module(), opts()) :: Plug.Conn.t()
  def run(%Plug.Conn{} = conn, tool, opts \\ []) do
    guarded(conn, tool.name(), fn ->
      with {:ok, path_args} <- path_args(conn, tool, Keyword.get(opts, :path, [])),
           drop = Enum.map(Keyword.get(opts, :drop, []), &Atom.to_string/1),
           {:ok, args, requested} <- Params.tool_args(conn, tool, path_args, drop),
           {:ok, value} <- call(tool, args, requested, conn.assigns.current_scope) do
        data(conn, Keyword.get(opts, :status, 200), value)
      end
    end)
  end

  @doc """
  Runs `fun`, which returns a sent `conn` or `{:error, reason}`: the error
  goes through `HelmsmanWeb.ErrorMapper`, and an exception is a 500 whose
  reference the log repeats with the details. `name` names the call in
  the log.
  """
  @spec guarded(Plug.Conn.t(), String.t(), (-> Plug.Conn.t() | {:error, term()})) ::
          Plug.Conn.t()
  def guarded(conn, name, fun) do
    case fun.() do
      %Plug.Conn{} = conn -> conn
      {:error, reason} -> error(conn, reason)
    end
  catch
    kind, reason ->
      details = "#{name}: " <> Exception.format(kind, reason, __STACKTRACE__)
      ErrorMapper.send_error(conn, ErrorMapper.internal(details))
  end

  @doc "Sends `{\"data\": value}` with `status`."
  @spec data(Plug.Conn.t(), pos_integer(), term()) :: Plug.Conn.t()
  def data(conn, status, value) do
    conn
    |> put_status(status)
    |> Phoenix.Controller.json(%{data: value})
  end

  @doc "Sends the error response of the domain error `reason`."
  @spec error(Plug.Conn.t(), term()) :: Plug.Conn.t()
  def error(conn, reason), do: ErrorMapper.send_error(conn, ErrorMapper.to_response(reason))

  @doc """
  The request's current identity for a read (`Helmsman.Actors.resolve_reader/2`)
  in `scope.actor`, with its source; the actor's name goes into the
  Logger metadata (`api_actor`).
  """
  @spec reader_scope(Scope.t(), String.t() | nil) ::
          {:ok, Scope.t(), Actors.reader_source()} | {:error, term()}
  def reader_scope(%Scope{} = scope, requested) do
    with {:ok, actor, source} <- Actors.resolve_reader(scope, requested) do
      Logger.metadata(api_actor: actor.name)
      {:ok, %{scope | actor: actor}, source}
    end
  end

  @doc """
  Runs the write `fun` as the request's writer (`Helmsman.Actors.with_writer/3`,
  never creating a session agent). Returns `{:ok, value}` after the
  commit, a `%HelmsmanMCP.Rejected{}` value as `{:error, reason}`.
  """
  @spec write(Scope.t(), String.t() | nil, (Scope.t() -> {:ok, term()} | {:error, term()})) ::
          {:ok, term()} | {:error, term()}
  def write(%Scope{} = scope, requested, fun) do
    case Actors.with_writer(scope, [requested: requested, auto_agent: false], fun) do
      {:ok, value, %{actor: actor}} ->
        Logger.metadata(api_actor: actor.name)
        committed(value)

      {:error, _reason} = error ->
        error
    end
  end

  @doc """
  A path parameter that must be a positive integer (a run, filter or
  autopilot ID): anything else is `{:error, :not_found}`.
  """
  @spec positive_id(String.t() | nil) :: {:ok, pos_integer()} | {:error, :not_found}
  def positive_id(value) when is_binary(value) do
    case Integer.parse(value) do
      {id, ""} when id > 0 -> {:ok, id}
      _other -> {:error, :not_found}
    end
  end

  def positive_id(_value), do: {:error, :not_found}

  ## Tools

  defp call(tool, args, requested, scope) do
    ctx = %Context{tool: tool.name(), args: args, scope: scope, session: nil}

    case tool.mode() do
      :read ->
        with {:ok, scope, _source} <- reader_scope(scope, requested),
             do: tool.call(args, %{ctx | scope: scope})

      :write ->
        write(scope, requested, &tool.call(args, %{ctx | scope: &1}))
    end
  end

  defp committed(%Rejected{reason: reason}), do: {:error, reason}
  defp committed(value), do: {:ok, value}

  defp path_args(conn, tool, specs) do
    schema = Params.peri_schema(tool)

    Enum.reduce_while(specs, {:ok, %{}}, fn {arg, spec}, {:ok, acc} ->
      case path_value(conn.path_params, spec, integer_arg?(schema, arg)) do
        {:ok, value} -> {:cont, {:ok, Map.put(acc, Atom.to_string(arg), value)}}
        error -> {:halt, error}
      end
    end)
  end

  defp path_value(params, {:feedback_id, id, seq}, _integer?) do
    with {:ok, seq} <- positive_id(params[seq]), do: {:ok, "#{params[id]}##{seq}"}
  end

  defp path_value(params, {:integer, name}, _integer?), do: positive_id(params[name])
  defp path_value(params, name, true), do: positive_id(params[name])
  defp path_value(params, name, false), do: {:ok, params[name]}

  defp integer_arg?(schema, arg), do: base(Map.get(schema, arg)) == :integer

  defp base({:required, type}), do: base(type)
  defp base({:meta, type, _opts}), do: base(type)
  defp base(type), do: type
end
