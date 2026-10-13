defmodule HelmsmanWeb.CommandPalette.TaskSearch do
  @moduledoc """
  "任务" (add-search-query-ui D1): full-text hits of `Helmsman.Search.search/3` for a
  query that is not blank and not a `KEY-N` (`HelmsmanWeb.CommandPalette.Ident` jumps to
  those), at most #{8} with ID, title and status icon; then 「在查询页搜索 "<输入>"」,
  which opens the BQL page with `text ~ "<输入>"`.

  Snippets may be nil (a hit in the ID, the title or a label, an empty description):
  `Search.Snippet.to_html/1` (which escapes every segment) is only called on a non-empty
  list, and the only other HTML is the escaped author name of a feedback hit.
  """
  @behaviour HelmsmanWeb.CommandPalette.Source
  use Gettext, backend: HelmsmanWeb.Gettext

  alias Helmsman.Accounts.Scope
  alias Helmsman.Search
  alias Helmsman.Search.Snippet
  alias HelmsmanWeb.CommandPalette.Ident
  alias HelmsmanWeb.Components.Status

  @limit 8

  @impl true
  # The /dev/ui demo scope (a plain map) has no tasks to search.
  def search(%Scope{workspace: %{slug: slug}} = scope, query, _ctx) do
    query = String.trim(query)

    cond do
      query == "" -> []
      Ident.parse(query) -> []
      true -> hits(scope, slug, query) ++ [query_page(slug, query)]
    end
  end

  def search(_scope, _query, _ctx), do: []

  defp hits(scope, slug, query) do
    case Search.search(scope, query, limit: @limit) do
      {:ok, hits} -> Enum.map(hits, &result(&1, slug))
      {:error, _} -> []
    end
  end

  defp result(%{task: task} = hit, slug) do
    %{
      group: dgettext("ui", "任务"),
      label: "#{task.id} #{task.title}",
      icon: Status.task_status(task.status).icon,
      path: path(slug, task.id, hit.feedback)
    }
    |> Map.merge(sublabel(hit))
  end

  defp path(slug, ident, %{id: id}) when is_binary(id) do
    case String.split(id, "#", parts: 2) do
      [_ident, seq] -> "/w/#{slug}/t/#{ident}#feedback-#{seq}"
      _ -> "/w/#{slug}/t/#{ident}"
    end
  end

  defp path(slug, ident, _feedback), do: "/w/#{slug}/t/#{ident}"

  @doc false
  def sublabel(%{feedback: %{author: %{name: author}, snippet: [_ | _] = segments}}) do
    {:safe, html} = Snippet.to_html(segments)
    {:safe, name} = Phoenix.HTML.html_escape(author)
    %{sublabel_html: {:safe, [name, "：", html]}}
  end

  def sublabel(%{feedback: %{author: %{name: author}, id: id}}) do
    seq = id |> String.split("#") |> List.last()
    %{sublabel: dgettext("ui", "%{author} 的 Feedback #%{seq}", author: author, seq: seq)}
  end

  def sublabel(%{snippet: [_ | _] = segments}), do: %{sublabel_html: Snippet.to_html(segments)}
  def sublabel(_hit), do: %{}

  defp query_page(slug, query) do
    bql = ~s(text ~ "#{quote_bql(query)}")

    %{
      group: dgettext("ui", "任务"),
      label: dgettext("ui", "在查询页搜索 \"%{query}\"", query: query),
      icon: "lucide-square-terminal",
      path: "/w/#{slug}/query?" <> URI.encode_query(%{"bql" => bql})
    }
  end

  @doc ~S|The inside of a BQL double-quoted string (`\` → `\\`, `"` → `\"`).|
  def quote_bql(text), do: text |> String.replace("\\", "\\\\") |> String.replace("\"", "\\\"")
end
