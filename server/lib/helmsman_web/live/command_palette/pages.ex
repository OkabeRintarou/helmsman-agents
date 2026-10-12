defmodule HelmsmanWeb.CommandPalette.Pages do
  @moduledoc """
  "页面": navigation items (from `HelmsmanWeb.Nav`) whose label, hint (a project's key)
  or group label matches the query.
  """
  @behaviour HelmsmanWeb.CommandPalette.Source
  use Gettext, backend: HelmsmanWeb.Gettext

  @impl true
  def search(_scope, query, ctx) do
    case String.downcase(String.trim(query)) do
      "" ->
        []

      q ->
        for group <- Map.get(ctx, :nav, []),
            item <- group.items,
            Enum.any?(
              [item.label, Map.get(item, :hint), group.label],
              &(is_binary(&1) and String.contains?(String.downcase(&1), q))
            ) do
          %{
            group: dgettext("ui", "页面"),
            label: item.label,
            sublabel: group.label,
            icon: item.icon,
            path: item.path
          }
        end
    end
  end
end
