defmodule HelmsmanWeb.Components.FilterBar do
  @moduledoc """
  List filter bar: quick views, a "筛选" menu, removable chips for the active filters,
  a debounced search box and display options. All state lives in the URL: the menu and
  chips are `patch` links built with `HelmsmanWeb.Filters`, and the search box sends
  `search_event` (debounced 300ms) for the LiveView to `push_patch/2`.
  """
  use Phoenix.Component
  use Gettext, backend: HelmsmanWeb.Gettext

  import HelmsmanWeb.CoreComponents, only: [icon: 1]
  import HelmsmanWeb.Components.Menu, only: [dropdown: 1]

  alias HelmsmanWeb.Filters

  @doc """
  * `dimensions`: `[%{key: :status, label: "状态", options: [{"new", "新建"}, …]}]`;
    `single: true` makes a dimension single-select (choosing an option replaces the
    current value, choosing it again clears it; see `HelmsmanWeb.Filters.put_single/3`)
  * `filters`: the parsed filter map (see `HelmsmanWeb.Filters.parse/2`)
  * `path`: the list's base path (without query)
  * `search`: `false` leaves out the search box (and so the `/` shortcut does nothing)
  """
  attr :id, :string, required: true
  attr :path, :string, required: true
  attr :filters, :map, required: true
  attr :dimensions, :list, required: true
  attr :search_event, :string, default: "search"
  attr :search_key, :atom, default: :q
  attr :search, :boolean, default: true
  slot :views, doc: "quick view tabs (left)"
  slot :display, doc: "display options (right)"

  def filter_bar(assigns) do
    assigns =
      assign(assigns,
        chips: chips(assigns.dimensions, assigns.filters, assigns.path),
        menu_items: menu_items(assigns.dimensions, assigns.filters, assigns.path)
      )

    ~H"""
    <div id={@id} class="flex flex-wrap items-center gap-2 px-4 py-2">
      <div :if={@views != []} class="flex items-center gap-1">{render_slot(@views)}</div>
      <.dropdown
        id={"#{@id}-menu"}
        items={@menu_items}
        label={dgettext("ui", "筛选")}
        trigger_class="h-7 px-2 text-label text-fg-muted border border-dashed border-border-strong"
      >
        <:trigger>
          <.icon name="lucide-list-filter" class="size-3.5" />{dgettext("ui", "筛选")}
        </:trigger>
      </.dropdown>
      <.filter_chip
        :for={chip <- @chips}
        id={"#{@id}-chip-#{chip.key}"}
        label={chip.label}
        values={chip.values}
        remove={chip.remove}
      />
      <form
        :if={@search}
        id={"#{@id}-search"}
        role="search"
        phx-change={@search_event}
        phx-submit={@search_event}
        class="ml-auto"
      >
        <label class="relative flex items-center">
          <span class="sr-only">{dgettext("ui", "搜索")}</span>
          <.icon
            name="lucide-search"
            class="pointer-events-none absolute left-2 size-3.5 text-fg-subtle"
          />
          <input
            type="search"
            name={@search_key}
            value={@filters[@search_key]}
            phx-debounce="300"
            data-hm-filter-input
            placeholder={dgettext("ui", "搜索…")}
            class="h-7 w-48 rounded-field border border-border-strong bg-surface pl-7 pr-2 text-label text-fg focus:border-brand focus:outline-none"
          />
        </label>
      </form>
      <div :if={@display != []} class="flex items-center gap-1">{render_slot(@display)}</div>
    </div>
    """
  end

  @doc "One active filter: \"状态：新建、进行中\" with a remove link."
  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :values, :string, required: true
  attr :remove, :string, required: true, doc: "URL without this filter"

  def filter_chip(assigns) do
    ~H"""
    <span
      id={@id}
      class="inline-flex h-7 items-center gap-1 rounded-field border border-border bg-surface pl-2 text-label"
    >
      <span class="text-fg-muted">{@label}：</span>
      <span class="max-w-56 truncate text-fg">{@values}</span>
      <.link
        patch={@remove}
        aria-label={dgettext("ui", "移除筛选：%{label}", label: @label)}
        class="inline-flex size-7 items-center justify-center rounded-field text-fg-muted hover:bg-hover hover:text-fg"
      >
        <.icon name="lucide-x" class="size-3.5" />
      </.link>
    </span>
    """
  end

  defp chips(dimensions, filters, path) do
    for %{key: key, label: label} = dim <- dimensions,
        values = List.wrap(Map.get(filters, key)),
        values != [] do
      names = Enum.map(values, &option_label(dim, &1))

      %{
        key: key,
        label: label,
        values: Enum.join(names, "、"),
        remove: Filters.path(path, Map.delete(filters, key))
      }
    end
  end

  defp menu_items(dimensions, filters, path) do
    for %{key: key, label: label} = dim <- dimensions,
        {value, name} <- Map.get(dim, :options, []) do
      %{
        id: "filter-#{key}-#{value}",
        group: label,
        label: name,
        checked: value in List.wrap(Map.get(filters, key)),
        patch: Filters.path(path, select(dim, filters, key, value))
      }
    end
  end

  defp select(%{single: true}, filters, key, value), do: Filters.put_single(filters, key, value)
  defp select(_dim, filters, key, value), do: Filters.toggle(filters, key, value)

  defp option_label(dim, value) do
    case List.keyfind(Map.get(dim, :options, []), value, 0) do
      {_, name} -> name
      nil -> value
    end
  end
end
