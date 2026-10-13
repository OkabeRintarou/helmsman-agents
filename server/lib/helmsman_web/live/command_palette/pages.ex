defmodule HelmsmanWeb.CommandPalette.Pages do
  @moduledoc """
  "页面": navigation items (from `HelmsmanWeb.Nav`) whose label, hint (a project's key)
  or group label matches the query, then the settings tabs (`HelmsmanWeb.Settings`)
  whose palette label matches it, then the personal pages outside the workspace
  (供应商账号, add-provider-accounts-ui D11).
  """
  @behaviour HelmsmanWeb.CommandPalette.Source
  use Gettext, backend: HelmsmanWeb.Gettext

  alias HelmsmanWeb.Settings

  @impl true
  def search(scope, query, ctx) do
    case String.downcase(String.trim(query)) do
      "" -> []
      q -> nav_items(q, ctx) ++ settings_tabs(scope, q) ++ personal_pages(q)
    end
  end

  defp nav_items(q, ctx) do
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

  defp settings_tabs(scope, q) do
    settings = dgettext("ui", "设置")

    for tab <- Settings.tabs(scope),
        Enum.any?([tab.palette_label, settings], &String.contains?(String.downcase(&1), q)) do
      %{
        group: dgettext("ui", "页面"),
        label: tab.palette_label,
        sublabel: settings,
        icon: "lucide-settings",
        path: tab.path
      }
    end
  end

  defp personal_pages(q) do
    personal = dgettext("ui", "个人设置")
    label = dgettext("ui", "供应商账号")

    if Enum.any?([label, "provider", personal], &String.contains?(String.downcase(&1), q)) do
      [
        %{
          group: dgettext("ui", "页面"),
          label: label,
          sublabel: personal,
          icon: "lucide-key-round",
          path: "/users/settings/provider-accounts"
        }
      ]
    else
      []
    end
  end
end
