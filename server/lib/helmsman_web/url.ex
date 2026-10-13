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

  @doc """
  The path of the agent page of `name` in the workspace `slug`. The name's `/` stay path
  separators (`/w/acme/agents/keel/dev`); a name with an empty segment (`//` or a trailing
  `/`, which the path would lose) is one segment with `/` encoded as `%2F`.

      iex> HelmsmanWeb.Url.agent_path("acme", "keel/dev")
      "/w/acme/agents/keel/dev"
  """
  @spec agent_path(String.t(), String.t()) :: String.t()
  def agent_path(slug, name) do
    encoded =
      if Enum.any?(String.split(name, "/"), &(&1 == "")),
        do: URI.encode(name, &URI.char_unreserved?/1),
        else: name |> String.split("/") |> Enum.map_join("/", &encode_segment/1)

    "/w/#{slug}/agents/#{encoded}"
  end

  defp encode_segment(segment), do: URI.encode(segment, &URI.char_unreserved?/1)

  @doc "The conversation page (用对话创建 Agent) of the workspace `slug`."
  @spec agent_design_path(String.t()) :: String.t()
  def agent_design_path(slug), do: "/w/#{slug}/agent-design"

  @doc "The agent name of the `*name` glob segments of `agent_path/2`."
  @spec agent_name([String.t()]) :: String.t()
  def agent_name(segments) when is_list(segments), do: Enum.join(segments, "/")

  defp update(uri, fun) do
    %URI{path: path, query: query} = URI.parse(uri)

    case (query || "") |> Query.decode() |> fun.() do
      params when map_size(params) == 0 -> path || "/"
      params -> (path || "/") <> "?" <> Query.encode(Enum.sort(params))
    end
  end
end
