defmodule HelmsmanProtocol.Schema do
  @moduledoc """
  Small declaration DSL for the protocol's structs and map codecs.

  `new/1` accepts atom-keyed attributes (including nested structs), while
  `from_wire/1` accepts string-keyed JSON objects. Both validate all fields.
  Nullable fields may be omitted and are always encoded as null.
  """
  @type error :: {:invalid_payload, [String.t() | non_neg_integer()], term()}

  defmacro __using__(_opts) do
    quote do
      import HelmsmanProtocol.Schema,
        only: [field: 2, field: 3, embeds: 2, embeds: 3, list: 2, list: 3]

      Module.register_attribute(__MODULE__, :protocol_fields, accumulate: true)
      @before_compile HelmsmanProtocol.Schema
    end
  end

  defmacro field(name, type, opts \\ []) do
    quote do
      @protocol_fields {unquote(name), unquote(type), unquote(opts)}
    end
  end

  defmacro embeds(name, module, opts \\ []) do
    quote do
      field(unquote(name), {:embed, unquote(module)}, unquote(opts))
    end
  end

  defmacro list(name, type, opts \\ []) do
    quote do
      field(unquote(name), {:list, unquote(type)}, unquote(opts))
    end
  end

  defmacro __before_compile__(env) do
    fields = env.module |> Module.get_attribute(:protocol_fields) |> Enum.reverse()
    compiled = Enum.map(fields, fn {name, type, opts} -> {name, compile_type(type), opts} end)

    struct_fields =
      Enum.map(fields, fn {name, _, opts} -> {name, Keyword.get(opts, :default)} end)

    types = Enum.map(fields, fn {name, type, opts} -> {name, field_type(type, opts)} end)

    definitions =
      for name <- [:new, :from_wire, :to_wire, :validate],
          not Module.defines?(env.module, {name, 1}),
          do: definition(name)

    quote do
      defstruct unquote(struct_fields)
      @type t :: %__MODULE__{unquote_splicing(types)}
      @schema unquote(Macro.escape(compiled))
      @doc false
      def __schema__, do: @schema
      unquote_splicing(definitions)
    end
  end

  defp definition(:new) do
    quote do
      @spec new(map() | keyword()) :: {:ok, t()} | {:error, HelmsmanProtocol.Schema.error()}
      def new(attrs), do: HelmsmanProtocol.Schema.decode(__MODULE__, @schema, attrs, :native)
    end
  end

  defp definition(:from_wire) do
    quote do
      @spec from_wire(map()) :: {:ok, t()} | {:error, HelmsmanProtocol.Schema.error()}
      def from_wire(attrs), do: HelmsmanProtocol.Schema.decode(__MODULE__, @schema, attrs, :wire)
    end
  end

  defp definition(:to_wire) do
    quote do
      @spec to_wire(t()) :: map()
      def to_wire(%__MODULE__{} = value), do: HelmsmanProtocol.Schema.encode(value, @schema)
    end
  end

  defp definition(:validate) do
    quote do
      @doc false
      def validate(value), do: {:ok, value}
    end
  end

  defp compile_type({:enum, allowed}),
    do: {:enum, allowed, Map.new(allowed, &{Atom.to_string(&1), &1})}

  defp compile_type({:list, type}), do: {:list, compile_type(type)}
  defp compile_type(type), do: type

  defp field_type(type, opts) do
    ast = type_ast(type)
    if opts[:nullable], do: quote(do: unquote(ast) | nil), else: ast
  end

  defp type_ast(:pos_integer), do: quote(do: pos_integer())
  defp type_ast(:non_neg_integer), do: quote(do: non_neg_integer())
  defp type_ast(:number), do: quote(do: non_neg_integer() | float())
  defp type_ast(:string), do: quote(do: String.t())
  defp type_ast(:boolean), do: quote(do: boolean())
  defp type_ast(:datetime), do: quote(do: DateTime.t())
  defp type_ast(:string_map), do: quote(do: %{String.t() => String.t()})
  defp type_ast(:json_object), do: quote(do: map())
  defp type_ast({:embed, module}), do: quote(do: unquote(module).t())

  defp type_ast({:list, module})
       when is_atom(module) and module not in [:string, :pos_integer, :non_neg_integer],
       do: quote(do: [unquote(module).t()])

  defp type_ast({:list, type}), do: quote(do: [unquote(type_ast(type))])
  defp type_ast({:enum, values}), do: Enum.reduce(values, &{:|, [], [&1, &2]})
  defp type_ast({:variant, _, _}), do: quote(do: struct())

  @doc false
  def decode(module, fields, attrs, mode) when is_list(attrs) and mode == :native do
    if Keyword.keyword?(attrs),
      do: decode(module, fields, Map.new(attrs), mode),
      else: invalid([], :type)
  end

  def decode(module, fields, attrs, mode) when is_map(attrs) and not is_struct(attrs) do
    fields
    |> Enum.reduce_while({:ok, %{}}, &decode_field(&1, &2, attrs, mode))
    |> case do
      {:ok, values} -> module.validate(struct(module, values))
      error -> error
    end
  end

  def decode(_, _, _, _), do: invalid([], :type)

  defp decode_field({name, type, opts}, {:ok, values}, attrs, mode) do
    key = if mode == :wire, do: Atom.to_string(name), else: name
    path = [Atom.to_string(name)]

    result = decode_present(Map.fetch(attrs, key), type, opts, mode, values, path)

    case result do
      {:ok, value} -> {:cont, {:ok, Map.put(values, name, value)}}
      error -> {:halt, error}
    end
  end

  defp decode_present(:error, _, opts, _, _, path) do
    cond do
      Keyword.has_key?(opts, :default) -> {:ok, opts[:default]}
      opts[:nullable] == true and opts[:required] != true -> {:ok, nil}
      true -> invalid(path, :required)
    end
  end

  defp decode_present({:ok, nil}, _, opts, _, _, path) do
    if opts[:nullable], do: {:ok, nil}, else: invalid(path, :type)
  end

  defp decode_present({:ok, value}, type, opts, mode, values, path) do
    decode_value(type, value, opts, mode, values) |> prefix(path)
  end

  defp decode_value(:pos_integer, value, _, _, _) when is_integer(value) and value > 0,
    do: {:ok, value}

  defp decode_value(:non_neg_integer, value, _, _, _) when is_integer(value) and value >= 0,
    do: {:ok, value}

  defp decode_value(:number, value, _, _, _) when is_number(value) and value >= 0,
    do: {:ok, value}

  defp decode_value(:boolean, value, _, _, _) when is_boolean(value), do: {:ok, value}

  defp decode_value(:string, value, opts, _, _) when is_binary(value) do
    cond do
      not String.valid?(value) ->
        invalid([], :type)

      byte_size(value) < Keyword.get(opts, :min_bytes, 0) ->
        invalid([], :type)

      opts[:max_bytes] && byte_size(value) > opts[:max_bytes] ->
        invalid([], {:too_long, opts[:max_bytes]})

      true ->
        {:ok, value}
    end
  end

  defp decode_value({:enum, allowed, lookup}, value, _, mode, _) do
    cond do
      mode == :native and value in allowed -> {:ok, value}
      is_binary(value) and Map.has_key?(lookup, value) -> {:ok, Map.fetch!(lookup, value)}
      true -> invalid([], {:enum, allowed})
    end
  end

  defp decode_value(:datetime, %DateTime{utc_offset: 0, std_offset: 0} = value, _, :native, _) do
    DateTime.from_iso8601(DateTime.to_iso8601(value)) |> utc_datetime()
  end

  defp decode_value(:datetime, value, _, _, _) when is_binary(value) do
    value |> DateTime.from_iso8601() |> utc_datetime()
  end

  defp decode_value(:string_map, value, _, _, _) when is_map(value) and not is_struct(value) do
    if Enum.all?(value, fn {k, v} ->
         is_binary(k) and is_binary(v) and String.valid?(k) and String.valid?(v)
       end), do: {:ok, value}, else: invalid([], :type)
  end

  defp decode_value(:json_object, value, _, _, _) when is_map(value) and not is_struct(value) do
    if json?(value), do: {:ok, value}, else: invalid([], :type)
  end

  defp decode_value({:embed, module}, value, _, mode, _), do: decode_embed(module, value, mode)

  defp decode_value({:variant, selector, modules}, value, _, mode, values) do
    decode_embed(Map.fetch!(modules, Map.fetch!(values, selector)), value, mode)
  end

  defp decode_value({:list, type}, value, opts, mode, _) when is_list(value) do
    min = Keyword.get(opts, :min, 0)
    max = Keyword.get(opts, :max, :infinity)
    count = length(value)

    if count < min or (max != :infinity and count > max),
      do: invalid([], {:count, min, max}),
      else: decode_list(value, type, opts, mode)
  end

  defp decode_value(_, _, _, _, _), do: invalid([], :type)

  defp decode_list(value, type, opts, mode) do
    value
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {item, index}, {:ok, acc} ->
      case decode_item(type, item, opts, mode) |> prefix([index]) do
        {:ok, decoded} -> {:cont, {:ok, [decoded | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, items} -> {:ok, Enum.reverse(items)}
      error -> error
    end
  end

  defp decode_item(type, value, _, mode)
       when is_atom(type) and type not in [:string, :pos_integer, :non_neg_integer],
       do: decode_embed(type, value, mode)

  defp decode_item(type, value, opts, mode) do
    item_opts = [min_bytes: Keyword.get(opts, :item_min_bytes, 0)]

    item_opts =
      if opts[:item_max_bytes],
        do: Keyword.put(item_opts, :max_bytes, opts[:item_max_bytes]),
        else: item_opts

    decode_value(type, value, item_opts, mode, %{})
  end

  defp decode_embed(module, %{__struct__: module} = value, :native),
    do: module.new(Map.from_struct(value))

  defp decode_embed(module, value, :native), do: module.new(value)
  defp decode_embed(module, value, :wire), do: module.from_wire(value)
  defp utc_datetime({:ok, value, 0}), do: {:ok, value}
  defp utc_datetime(_), do: invalid([], :type)

  defp json?(value) when is_map(value) and not is_struct(value) do
    Enum.all?(value, fn {key, item} -> is_binary(key) and String.valid?(key) and json?(item) end)
  end

  defp json?(value) when is_list(value), do: Enum.all?(value, &json?/1)
  defp json?(value) when is_binary(value), do: String.valid?(value)
  defp json?(value), do: is_number(value) or is_boolean(value) or is_nil(value)

  @doc false
  def encode(value, fields) do
    Map.new(fields, fn {name, _, _} ->
      {Atom.to_string(name), encode_value(Map.fetch!(value, name))}
    end)
  end

  defp encode_value(nil), do: nil
  defp encode_value(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp encode_value(%{__struct__: module} = value), do: module.to_wire(value)
  defp encode_value(value) when is_boolean(value), do: value
  defp encode_value(value) when is_atom(value), do: Atom.to_string(value)
  defp encode_value(value) when is_list(value), do: Enum.map(value, &encode_value/1)
  defp encode_value(value), do: value
  @doc false
  def invalid(path, reason), do: {:error, {:invalid_payload, path, reason}}

  defp prefix({:error, {:invalid_payload, path, reason}}, parent),
    do: invalid(parent ++ path, reason)

  defp prefix(result, _), do: result
end
