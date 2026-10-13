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
        badge: fn scope -> 3 end,                      # optional count / dot
        hint: "BOS",                                   # optional, tooltip / search
        match?: fn current_path, path -> … end,        # optional current-item test
        prefix?: false                                 # optional, see items_for/3
      }

  `match?` may also take three arguments, `fn current_path, item_path, query_params`
  (the item path without its query string), for items told apart by the query string
  (the saved filters of `filter_items/1`).

  A feature change registers its page by adding an item to `items/0`; features that
  are not registered do not appear. Groups are rendered in `groups/0` order and empty
  groups are hidden.
  """
  use Gettext, backend: HelmsmanWeb.Gettext

  @group_order [:my_work, :projects, :filters, :agents, :config]

  @doc "Registered navigation items (feature changes add theirs here)."
  def items do
    [
      %{
        id: :projects,
        group: :projects,
        label: fn -> dgettext("ui", "查看全部") end,
        icon: "lucide-layout-grid",
        path: &"/w/#{&1.workspace.slug}/projects"
      },
      %{
        id: :agents,
        group: :agents,
        label: "Agents",
        icon: "lucide-bot",
        path: &"/w/#{&1.workspace.slug}/agents"
      },
      %{
        id: :runtimes,
        group: :config,
        label: fn -> dgettext("ui", "运行时") end,
        icon: "lucide-server",
        path: &"/w/#{&1.workspace.slug}/settings/runtimes",
        visible?: &member?/1
      },
      %{
        id: :settings,
        group: :config,
        label: fn -> dgettext("ui", "设置") end,
        icon: "lucide-settings",
        path: &"/w/#{&1.workspace.slug}/settings"
      }
    ]
  end

  @doc """
  Navigation items of the given (unarchived) projects for the 项目 group, in the given
  order. Put them before `items/0` so 查看全部 comes last. A project's item is current on
  its task list and on the detail page of any of its tasks.
  """
  def project_items(projects) do
    for %{key: key, name: name} <- projects do
      %{
        id: {:project, key},
        group: :projects,
        label: name,
        hint: key,
        icon: "lucide-folder",
        path: &"/w/#{&1.workspace.slug}/p/#{key}",
        match?: fn current_path, path ->
          task_prefix = String.replace_suffix(path, "/p/#{key}", "/t/#{key}-")
          current_path == path or String.starts_with?(current_path, task_prefix)
        end
      }
    end
  end

  @max_mine 15
  @max_shared 10

  @doc """
  Items of the 筛选器 group (add-search-query-ui D8): 查询, the user's own filters (by
  name, at most #{@max_mine}), filters others share (by name, at most #{@max_shared}, the
  owner or 所有者已离开 as hint) and, when some are left out, 全部筛选器 (the BQL page's
  `?panel=filters`). `filters` is `%{mine: [filter], shared: [filter]}` as listed by the
  domain (already sorted by name).

  A filter's item is current when the BQL page shows it (`?filter=<ID>`); 查询 is current
  on the BQL page without a filter.
  """
  def filter_items(%{mine: mine, shared: shared}) do
    more =
      if length(mine) > @max_mine or length(shared) > @max_shared,
        do: [all_filters_item()],
        else: []

    [query_item()] ++
      Enum.map(Enum.take(mine, @max_mine), &filter_item(&1, "lucide-funnel", nil)) ++
      Enum.map(Enum.take(shared, @max_shared), &filter_item(&1, "lucide-users", owner_hint(&1))) ++
      more
  end

  defp query_item do
    %{
      id: :query,
      group: :filters,
      label: fn -> dgettext("ui", "查询") end,
      icon: "lucide-square-terminal",
      path: &"/w/#{&1.workspace.slug}/query",
      prefix?: false,
      match?: fn current, path, params ->
        current == path and blank?(params["filter"]) and params["panel"] != "filters"
      end
    }
  end

  defp filter_item(filter, icon, hint) do
    id = to_string(filter.id)

    %{
      id: {:filter, id},
      group: :filters,
      label: filter.name,
      hint: hint,
      icon: icon,
      path: &"/w/#{&1.workspace.slug}/query?filter=#{id}",
      prefix?: false,
      match?: fn current, path, params -> current == path and params["filter"] == id end
    }
  end

  defp all_filters_item do
    %{
      id: :all_filters,
      group: :filters,
      label: fn -> dgettext("ui", "全部筛选器") end,
      icon: "lucide-list-filter",
      path: &"/w/#{&1.workspace.slug}/query?panel=filters",
      prefix?: false,
      match?: fn current, path, params ->
        current == path and blank?(params["filter"]) and params["panel"] == "filters"
      end
    }
  end

  defp owner_hint(filter) do
    case HelmsmanWeb.QueryData.owner_name(filter) do
      nil -> dgettext("ui", "所有者已离开")
      name -> name
    end
  end

  defp blank?(value), do: value in [nil, ""]

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

  `current_path` may carry a query string (`/w/acme/query?filter=3`); only items whose
  `match?` takes three arguments look at it. The current item is the first whose `match?`
  returns true, otherwise the one with the longest path that prefixes the current path
  (items with `prefix?: false` are only current through `match?`).

  Returns `[%{id: group, label: String.t(), items: [%{id, label, hint, icon, path, badge, current?}]}]`.
  """
  def items_for(scope, current_path, items \\ items()) do
    resolved =
      for item <- items, visible?(item, scope) do
        %{
          id: item.id,
          group: item.group,
          label: resolve(item.label),
          hint: Map.get(item, :hint),
          icon: item.icon,
          path: item.path.(scope),
          badge: if(badge = Map.get(item, :badge), do: badge.(scope)),
          match?: Map.get(item, :match?),
          prefix?: Map.get(item, :prefix?, true)
        }
      end

    current = current_item(resolved, current_path)
    resolved = Enum.map(resolved, &Map.drop(&1, [:match?, :prefix?]))

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

  defp member?(%{role: role}), do: role in [:owner, :admin, :member]
  defp member?(_scope), do: false

  defp visible?(item, scope) do
    case Map.get(item, :visible?) do
      nil -> true
      fun -> fun.(scope) == true
    end
  end

  defp resolve(label) when is_function(label, 0), do: label.()
  defp resolve(label), do: label

  defp current_item(_items, nil), do: nil

  defp current_item(items, current) do
    %URI{path: current_path, query: query} = URI.parse(current)
    params = URI.decode_query(query || "")

    case Enum.find(items, &matches?(&1, current_path, params)) do
      nil -> longest_prefix_item(items, current_path)
      item -> item.id
    end
  end

  defp matches?(%{match?: nil}, _current_path, _params), do: false

  defp matches?(%{match?: fun, path: path}, current_path, _params) when is_function(fun, 2),
    do: fun.(current_path, path)

  defp matches?(%{match?: fun, path: path}, current_path, params) when is_function(fun, 3),
    do: fun.(current_path, URI.parse(path).path, params)

  defp longest_prefix_item(items, current_path) do
    items
    |> Enum.filter(fn %{path: path, prefix?: prefix?} ->
      path = path |> URI.parse() |> Map.get(:path)
      prefix? and (current_path == path or String.starts_with?(current_path, path <> "/"))
    end)
    |> Enum.max_by(&String.length(&1.path), fn -> nil end)
    |> case do
      nil -> nil
      item -> item.id
    end
  end
end
