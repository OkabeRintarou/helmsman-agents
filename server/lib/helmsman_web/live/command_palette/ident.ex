defmodule HelmsmanWeb.CommandPalette.Ident do
  @moduledoc """
  "跳转到任务": a query shaped like `KEY-N` (case-insensitive) yields a jump to
  `/w/<slug>/t/KEY-N` without querying the database (the task page 404s if it does not
  exist). An empty query lists the recently visited tasks.

  Parsing is `Helmsman.Tasks.Ident.parse/1` (format only, no database lookup).
  """
  @behaviour HelmsmanWeb.CommandPalette.Source
  use Gettext, backend: HelmsmanWeb.Gettext

  alias Helmsman.Tasks.Ident, as: TaskIdent

  @impl true
  def search(scope, query, ctx) do
    case slug(scope) do
      nil -> []
      slug -> results(slug, String.trim(query), ctx)
    end
  end

  defp results(slug, "", ctx) do
    for raw <- Map.get(ctx, :recent_tasks, []), ident = parse(raw) do
      item(slug, ident, dgettext("ui", "最近访问"))
    end
  end

  defp results(slug, query, _ctx) do
    case parse(query) do
      nil -> []
      ident -> [item(slug, ident, dgettext("ui", "跳转到任务"))]
    end
  end

  @doc ~S|Normalizes a `KEY-N` string (`"bos-12"` → `"BOS-12"`); `nil` if it is not a valid ident.|
  def parse(text) when is_binary(text) do
    case TaskIdent.parse(String.trim(text)) do
      {:ok, ident, _key, _seq} -> ident
      {:error, _} -> nil
    end
  end

  def parse(_text), do: nil

  defp item(slug, ident, group) do
    %{group: group, label: ident, icon: "lucide-arrow-right", path: "/w/#{slug}/t/#{ident}"}
  end

  defp slug(%{workspace: %{slug: slug}}), do: slug
  defp slug(_scope), do: nil
end
