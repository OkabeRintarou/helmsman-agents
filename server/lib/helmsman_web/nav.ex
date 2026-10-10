defmodule HelmsmanWeb.Nav do
  @moduledoc """
  Central registry of the sidebar navigation.

  Each item is a map:

      %{
        id: :projects,
        group: :projects,
        label: fn -> dgettext("ui", "查看全部") end,   # or a plain string
        icon: "lucide-folder",
        path: fn scope -> "/w/\#{scope.workspace.slug}/projects" end,
        visible?: fn scope -> true end,                # optional
        badge: fn scope -> 3 end                       # optional count / dot
      }

  A feature change registers its page by adding an item to `items/0`; features that
  are not registered do not appear. Groups are rendered in `groups/0` order and empty
  groups are hidden.
  """
  use Gettext, backend: HelmsmanWeb.Gettext

  @group_order [:my_work, :projects, :filters, :agents, :config]

  @doc "Registered navigation items (feature changes add theirs here)."
  def items, do: []

  @doc "Group ids in display order."
  def groups, do: @group_order

  @doc false
  def group_label(:my_work), do: dgettext("ui", "我的工作")
  def group_label(:projects), do: dgettext("ui", "项目")
  def group_label(:filters), do: dgettext("ui", "筛选器")
  def group_label(:agents), do: dgettext("ui", "Agent 团队")
  def group_label(:config), do: dgettext("ui", "配置")

  @doc """
  Resolves the items visible to `scope`, grouped and in order, marking the item whose
  path best matches `current_path` with `current?: true`.

  Returns `[%{id: group, label: String.t(), items: [%{id, label, icon, path, badge, current?}]}]`.
  """
  def items_for(scope, current_path, items \\ items()) do
    resolved =
      for item <- items, visible?(item, scope) do
        %{
          id: item.id,
          group: item.group,
          label: resolve(item.label),
          icon: item.icon,
          path: item.path.(scope),
          badge: if(badge = Map.get(item, :badge), do: badge.(scope))
        }
      end

    current = current_item(resolved, current_path)

    for group <- @group_order,
        group_items = Enum.filter(resolved, &(&1.group == group)),
        group_items != [] do
      %{
        id: group,
        label: group_label(group),
        items: Enum.map(group_items, &Map.put(&1, :current?, &1.id == current))
      }
    end
  end

  defp visible?(item, scope) do
    case Map.get(item, :visible?) do
      nil -> true
      fun -> fun.(scope) == true
    end
  end

  defp resolve(label) when is_function(label, 0), do: label.()
  defp resolve(label), do: label

  defp current_item(_items, nil), do: nil

  defp current_item(items, current_path) do
    items
    |> Enum.filter(fn %{path: path} ->
      path = path |> URI.parse() |> Map.get(:path)
      current_path == path or String.starts_with?(current_path, path <> "/")
    end)
    |> Enum.max_by(&String.length(&1.path), fn -> nil end)
    |> case do
      nil -> nil
      item -> item.id
    end
  end
end
