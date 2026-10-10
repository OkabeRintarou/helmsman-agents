defmodule HelmsmanWeb.CommandPalette.Ident do
  @moduledoc """
  "跳转到任务": a query shaped like `KEY-N` (case-insensitive) yields a jump to
  `/w/<slug>/t/KEY-N` without querying the database (the task page 404s if it does not
  exist). An empty query lists the recently visited tasks.

  The format follows designs/04 (`ident`) and 01 (`projects.key`, `task_seq int`):
  key `[A-Z][A-Z0-9]{1,9}`, N a positive integer without leading zeros, at most 2^31 - 1.
  Replace with the domain parser once `add-projects-tasks` provides one.
  """
  @behaviour HelmsmanWeb.CommandPalette.Source
  use Gettext, backend: HelmsmanWeb.Gettext

  @ident ~r/^([A-Za-z][A-Za-z0-9]{1,9})-([1-9][0-9]{0,9})$/
  @max_seq 2_147_483_647

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
    with [_, key, n] <- Regex.run(@ident, String.trim(text)),
         true <- String.to_integer(n) <= @max_seq do
      "#{String.upcase(key)}-#{n}"
    else
      _ -> nil
    end
  end

  def parse(_text), do: nil

  defp item(slug, ident, group) do
    %{group: group, label: ident, icon: "lucide-arrow-right", path: "/w/#{slug}/t/#{ident}"}
  end

  defp slug(%{workspace: %{slug: slug}}), do: slug
  defp slug(_scope), do: nil
end
