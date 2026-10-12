defmodule HelmsmanWeb.Filters do
  @moduledoc """
  Converts list filters between URL query params and a filter map.

  A schema declares the known dimensions:

      schema = [status: {:list, ~w(new in_progress done)}, label: :list, q: :string]

  * `{:list, allowed}` / `:list`: comma separated values (`status=new,in_progress`).
    When a value itself contains a comma (labels may), the whole list is written as
    array params instead (`label[]=api,backend&label[]=ui`), which `parse/2` reads as is.
    Unknown values are dropped when `allowed` is given.
  * `:string`: a single trimmed string (search text).

  Empty dimensions are omitted, so `parse(to_query(filters), schema) == filters` for any
  filter map produced by `parse/2`.
  """

  alias Plug.Conn.Query

  @type schema :: keyword(:list | {:list, [String.t()]} | :string)
  @type t :: %{optional(atom()) => [String.t()] | String.t()}

  @doc "Parses query params (string keys) into a filter map."
  @spec parse(map(), schema()) :: t()
  def parse(params, schema) when is_map(params) do
    Enum.reduce(schema, %{}, fn {key, type}, acc ->
      case parse_value(Map.get(params, Atom.to_string(key)), type) do
        empty when empty in [nil, "", []] -> acc
        value -> Map.put(acc, key, value)
      end
    end)
  end

  defp parse_value(nil, _type), do: nil
  defp parse_value(value, :string) when is_binary(value), do: String.trim(value)

  defp parse_value(value, :list) when is_binary(value),
    do: value |> String.split(",") |> clean_list()

  defp parse_value(values, :list) when is_list(values),
    do: values |> Enum.filter(&is_binary/1) |> clean_list()

  defp parse_value(value, {:list, allowed}) when is_binary(value) or is_list(value),
    do: value |> parse_value(:list) |> Enum.filter(&(&1 in allowed))

  defp parse_value(_value, _type), do: nil

  defp clean_list(values),
    do: values |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == "")) |> Enum.uniq()

  @doc """
  Turns a filter map into query params (string keys). Lists are comma joined unless a
  value contains a comma; then the list is kept as a list (array params).
  """
  @spec to_query(t()) :: %{String.t() => String.t() | [String.t()]}
  def to_query(filters) do
    for {key, value} <- filters, value not in [nil, "", []], into: %{} do
      {Atom.to_string(key), encode_value(value)}
    end
  end

  defp encode_value(values) when is_list(values) do
    if Enum.any?(values, &String.contains?(&1, ",")), do: values, else: Enum.join(values, ",")
  end

  defp encode_value(value), do: value

  @doc "Builds `base_path?query` for the given filters (no `?` when empty)."
  @spec path(String.t(), t()) :: String.t()
  def path(base_path, filters) do
    case to_query(filters) do
      query when map_size(query) == 0 -> base_path
      query -> base_path <> "?" <> Query.encode(Enum.sort(query))
    end
  end

  @doc "Adds `value` to the list dimension `key`, or removes it if present."
  @spec toggle(t(), atom(), String.t()) :: t()
  def toggle(filters, key, value) do
    current = Map.get(filters, key, [])
    next = if value in current, do: List.delete(current, value), else: current ++ [value]
    if next == [], do: Map.delete(filters, key), else: Map.put(filters, key, next)
  end

  @doc """
  Sets the single-value dimension `key` to `value`, or removes it when it already is
  `value` (choosing the selected option again clears the dimension).

      iex> HelmsmanWeb.Filters.put_single(%{label: "api"}, :label, "ui")
      %{label: "ui"}

      iex> HelmsmanWeb.Filters.put_single(%{label: "api", status: ["new"]}, :label, "api")
      %{status: ["new"]}
  """
  @spec put_single(t(), atom(), String.t()) :: t()
  def put_single(filters, key, value) do
    if Map.get(filters, key) == value,
      do: Map.delete(filters, key),
      else: Map.put(filters, key, value)
  end
end
