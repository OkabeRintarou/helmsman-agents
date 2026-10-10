defmodule HelmsmanWeb.Components.MenuList do
  @moduledoc """
  Menu body with a filter box, used by `HelmsmanWeb.Components.Menu.dropdown/1` when
  there are more than 8 items. Filtering happens on the server (`phx-change`).
  """
  use Phoenix.LiveComponent
  use Gettext, backend: HelmsmanWeb.Gettext

  import HelmsmanWeb.Components.Menu, only: [menu_items: 1, filter_items: 2, first_selectable: 2]

  @impl true
  def mount(socket), do: {:ok, assign(socket, :query, "")}

  @impl true
  def update(assigns, socket), do: {:ok, assign(socket, assigns)}

  @impl true
  def handle_event("filter", %{"query" => query}, socket) do
    {:noreply, assign(socket, :query, query)}
  end

  # Enter in the filter box (Hotkeys): render the result for the current text and reply
  # with the item to activate; the reply reaches the client after the patch is applied.
  def handle_event("select_first", %{"query" => query}, socket) when is_binary(query) do
    reply =
      case first_selectable(socket.assigns.items, query) do
        nil -> %{}
        item -> %{id: item.id}
      end

    {:reply, reply, assign(socket, :query, query)}
  end

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :visible, filter_items(assigns.items, assigns.query))

    ~H"""
    <div id={@id} class="flex flex-col">
      <form
        id={"#{@menu_id}-filter-form"}
        phx-change="filter"
        phx-target={@myself}
        phx-submit="filter"
        class="p-1 pb-1.5"
      >
        <input
          type="text"
          name="query"
          value={@query}
          id={"#{@menu_id}-filter"}
          data-hm-menu-filter
          autocomplete="off"
          placeholder={dgettext("ui", "筛选…")}
          aria-label={dgettext("ui", "筛选选项")}
          aria-controls={"#{@menu_id}-menu"}
          phx-debounce="100"
          class="input input-sm h-7 w-full rounded-field border-border-strong bg-surface text-body shadow-none"
        />
      </form>
      <div class="max-h-72 overflow-y-auto">
        <.menu_items menu_id={@menu_id} label={@label} items={@visible} />
      </div>
    </div>
    """
  end
end
