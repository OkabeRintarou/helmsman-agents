defmodule HelmsmanWeb.Settings do
  @moduledoc """
  Registry of the workspace settings tabs (add-workspace-settings-ui D5). Later changes
  (运行时, GitHub, 数据) append theirs to `tabs/1`.

  Each tab is `%{id, label, palette_label, path}`; `palette_label` is what the command
  palette's 页面 group lists.
  """
  use Gettext, backend: HelmsmanWeb.Gettext

  @doc "The settings tabs of the scope's workspace, in display order."
  def tabs(%{workspace: %{slug: slug}}) do
    base = "/w/#{slug}/settings"

    [
      %{
        id: :general,
        label: dgettext("ui", "常规"),
        palette_label: dgettext("ui", "常规设置"),
        path: base
      },
      %{
        id: :members,
        label: dgettext("ui", "成员"),
        palette_label: dgettext("ui", "成员"),
        path: base <> "/members"
      },
      %{
        id: :tokens,
        label: dgettext("ui", "API Token"),
        palette_label: dgettext("ui", "API Token"),
        path: base <> "/tokens"
      }
    ]
  end

  def tabs(_scope), do: []

  @doc "The tab with `id`."
  def tab(scope, id), do: Enum.find(tabs(scope), &(&1.id == id))
end
