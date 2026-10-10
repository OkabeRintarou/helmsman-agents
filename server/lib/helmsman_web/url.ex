defmodule HelmsmanWeb.Url do
  @moduledoc """
  Changes single query parameters of a path while keeping the others (filters, tabs …),
  e.g. to open a `?panel=new` side panel and close it again without losing the filters.
  """

  alias Plug.Conn.Query

  @doc """
  Sets the given params on `uri` (a path with an optional query).

      iex> HelmsmanWeb.Url.put_params("/w/acme/tasks?status=new", %{"panel" => "new"})
      "/w/acme/tasks?panel=new&status=new"
  """
  @spec put_params(String.t(), map()) :: String.t()
  def put_params(uri, params) do
    update(uri, &Map.merge(&1, Map.new(params, fn {k, v} -> {to_string(k), v} end)))
  end

  @doc """
  Removes the given params from `uri`.

      iex> HelmsmanWeb.Url.drop_params("/w/acme/tasks?panel=new&status=new", ["panel"])
      "/w/acme/tasks?status=new"
  """
  @spec drop_params(String.t(), [String.t() | atom()]) :: String.t()
  def drop_params(uri, keys),
    do: update(uri, &Map.drop(&1, Enum.map(keys, fn k -> to_string(k) end)))

  defp update(uri, fun) do
    %URI{path: path, query: query} = URI.parse(uri)

    case (query || "") |> Query.decode() |> fun.() do
      params when map_size(params) == 0 -> path || "/"
      params -> (path || "/") <> "?" <> Query.encode(Enum.sort(params))
    end
  end
end
