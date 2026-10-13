defmodule HelmsmanWeb.API.Params do
  @moduledoc """
  The arguments of a REST call to an MCP tool (`add-rest-api` decision 4).

    * `GET` reads the query string, converted by the tool's
      `input_schema/0`: `integer` from a decimal string, `boolean` from
      `true` / `false`, a list (or a string-or-list) from a comma
      separated string or repeated `key[]=`;
    * other methods read the JSON body, which must be an object;
    * path parameters (already mapped to argument names) replace the same
      arguments of the query string or body.

  The result is checked against the tool's schema with `peri`, as anubis
  checks MCP calls: a missing required argument or a wrong type is
  `{:invalid_params, fields}`, and undeclared arguments are dropped.
  The requested identity comes from the `X-Helmsman-Actor` header or the
  body's `actor` / `author` (write tools); both given and different is
  `{:invalid_params, %{"actor" => [...]}}`.
  """

  alias Anubis.Server.Component

  @actor_header "x-helmsman-actor"
  @writer_keys ["actor", "author"]

  @type fields :: %{String.t() => [String.t()]}

  @doc """
  The tool arguments of `conn` for `tool` with `path_args` (string keys):
  `{:ok, args, requested}` with string keys at the top level (as
  `HelmsmanMCP.Pipeline` passes them), without `actor` / `author`, and
  the requested identity name or nil. The arguments named in `drop` are
  not taken from the request.
  """
  @spec tool_args(Plug.Conn.t(), module(), map(), [String.t()]) ::
          {:ok, map(), String.t() | nil} | {:error, {:invalid_params, fields()}}
  def tool_args(%Plug.Conn{} = conn, tool, path_args, drop \\ []) when is_map(path_args),
    do: args(conn, peri_schema(tool), path_args, drop)

  @doc """
  Like `tool_args/4` with a `peri` schema instead of a tool (REST-only
  endpoints declaring their own arguments). The arguments in `drop` and
  those `path_args` set are removed from the query string or body before
  anything is converted or checked, so a bad value there is ignored.
  """
  @spec args(Plug.Conn.t(), map(), map(), [String.t()]) ::
          {:ok, map(), String.t() | nil} | {:error, {:invalid_params, fields()}}
  def args(%Plug.Conn{} = conn, schema, path_args, drop \\ []) when is_map(path_args) do
    ignored = drop ++ Map.keys(path_args)

    with {:ok, input} <- input(conn, schema, ignored),
         {:ok, validated} <- validate(schema, Map.merge(input, path_args)),
         args = Map.new(validated, fn {key, value} -> {to_string(key), value} end),
         {:ok, requested} <- requested(conn, args) do
      {:ok, Map.drop(args, @writer_keys), requested}
    end
  end

  @doc """
  The identity requested by `X-Helmsman-Actor` and, when given, the
  body's `actor` / `author` (`body_actor`); conflicting names are
  `{:invalid_params, ...}`.
  """
  @spec requested_actor(Plug.Conn.t(), String.t() | nil) ::
          {:ok, String.t() | nil} | {:error, {:invalid_params, fields()}}
  def requested_actor(conn, body_actor) do
    case {header_actor(conn), body_actor} do
      {nil, body} -> {:ok, body}
      {header, nil} -> {:ok, header}
      {same, same} -> {:ok, same}
      _conflict -> {:error, {:invalid_params, %{"actor" => [conflict_message()]}}}
    end
  end

  @doc "The request body as an object: a JSON array or scalar is invalid."
  @spec body(Plug.Conn.t()) :: {:ok, map()} | {:error, {:invalid_params, fields()}}
  def body(%Plug.Conn{body_params: %{"_json" => _not_an_object}}),
    do: {:error, {:invalid_params, %{"body" => ["must be a JSON object"]}}}

  def body(%Plug.Conn{body_params: %{} = params}), do: {:ok, params}
  def body(%Plug.Conn{}), do: {:ok, %{}}

  @doc """
  The tool's schema as `peri` validates it (the anubis notation cleaned
  as anubis does for MCP calls).
  """
  @spec peri_schema(module()) :: map()
  def peri_schema(tool), do: Component.__clean_schema_for_peri__(tool.input_schema())

  @doc """
  Converts the query string `query` by the `peri` schema `schema`:
  undeclared keys are dropped, a value that cannot be converted is
  `{:invalid_params, fields}`.
  """
  @spec convert_query(map(), map()) :: {:ok, map()} | {:error, {:invalid_params, fields()}}
  def convert_query(query, schema) do
    {args, errors} =
      Enum.reduce(query, {%{}, %{}}, fn {key, value}, {args, errors} ->
        case declared_type(schema, key) do
          nil -> {args, errors}
          type -> put_converted(args, errors, key, convert(type, value))
        end
      end)

    if errors == %{}, do: {:ok, args}, else: {:error, {:invalid_params, errors}}
  end

  defp put_converted(args, errors, key, {:ok, value}), do: {Map.put(args, key, value), errors}

  defp put_converted(args, errors, key, {:error, message}),
    do: {args, Map.put(errors, key, [message])}

  ## Input

  defp input(%Plug.Conn{method: "GET"} = conn, schema, ignored) do
    conn = Plug.Conn.fetch_query_params(conn)
    conn.query_params |> Map.drop(ignored) |> convert_query(schema)
  end

  defp input(conn, _schema, ignored) do
    with {:ok, body} <- body(conn), do: {:ok, Map.drop(body, ignored)}
  end

  defp declared_type(schema, key) do
    Enum.find_value(schema, fn {name, type} -> if Atom.to_string(name) == key, do: base(type) end)
  end

  defp base({:required, type}), do: base(type)
  defp base({:meta, type, _opts}), do: base(type)
  defp base(type), do: type

  defp convert(:string, value) when is_binary(value), do: {:ok, value}
  defp convert(:integer, value) when is_binary(value), do: integer(value)
  defp convert(:boolean, "true"), do: {:ok, true}
  defp convert(:boolean, "false"), do: {:ok, false}
  defp convert(:boolean, _value), do: {:error, "must be true or false"}
  defp convert({:list, item}, value), do: list(item, value)

  defp convert({:oneof, types}, value) do
    case Enum.find(types, &match?({:list, _item}, base(&1))) do
      {:list, item} -> list(item, value)
      nil -> convert(base(hd(types)), value)
    end
  end

  defp convert(_type, value) when is_binary(value), do: {:ok, value}
  defp convert(_type, _value), do: {:error, "must be a single value"}

  defp integer(value) do
    case Integer.parse(value) do
      {integer, ""} -> {:ok, integer}
      _other -> {:error, "must be an integer"}
    end
  end

  defp list(item, value) when is_binary(value),
    do: list(item, String.split(value, ",", trim: true))

  defp list(item, values) when is_list(values) do
    Enum.reduce_while(Enum.reverse(values), {:ok, []}, fn value, {:ok, acc} ->
      case convert(base(item), value) do
        {:ok, converted} -> {:cont, {:ok, [converted | acc]}}
        {:error, message} -> {:halt, {:error, message}}
      end
    end)
  end

  defp list(_item, _value), do: {:error, "must be a list"}

  ## Validation

  defp validate(schema, input) do
    case Peri.validate(schema, input) do
      {:ok, validated} -> {:ok, validated}
      {:error, errors} -> {:error, {:invalid_params, fields(errors)}}
    end
  end

  defp fields(errors) do
    errors
    |> Enum.flat_map(&flatten/1)
    |> Enum.group_by(fn {path, _message} -> path end, fn {_path, message} -> message end)
  end

  defp flatten(%Peri.Error{errors: [_ | _] = nested}), do: Enum.flat_map(nested, &flatten/1)

  defp flatten(%Peri.Error{path: path, message: message}),
    do: [{Enum.map_join(path, ".", &to_string/1), message || "is invalid"}]

  ## Identity

  defp requested(conn, args),
    do: requested_actor(conn, Enum.find_value(@writer_keys, &args[&1]))

  defp header_actor(conn) do
    case Plug.Conn.get_req_header(conn, @actor_header) do
      [value | _] -> if String.trim(value) == "", do: nil, else: String.trim(value)
      [] -> nil
    end
  end

  defp conflict_message,
    do: "differs from the X-Helmsman-Actor header; give the identity once"
end
