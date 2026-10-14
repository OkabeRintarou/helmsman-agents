defmodule HelmsmanWeb.Components.Menu do
  @moduledoc """
  Pop-up menus anchored to a trigger (`dropdown/1`).

  Items are plain maps so the menu can count and filter them:

      %{label: "重命名", icon: "lucide-pencil", on_select: JS.push("rename")}
      %{label: "beta", checked: false, navigate: "/w/beta", description: "3 个项目"}
      %{label: "删除", danger: true, disabled_reason: "只有管理员可以删除"}
      %{type: :divider}

  Keys: `label` (required), `id`, `icon` (or `actor`: an identity map shown with
  `actor_mark/1`, or `brand`: a brand icon name, `:none` for the neutral one),
  `description`, `shortcut`, `checked`
  (`true`/`false` turns it into a `menuitemradio`; `:client` renders a check that CSS
  shows, for client-side state such as the theme), `group` (heading shown when it
  changes), `danger`, `disabled_reason`, `attrs` (extra HTML attributes), and one
  action: `on_select` (event name or `%JS{}`), `value` (params for an event),
  `navigate`, `patch` or `href` (with optional `method`).

  With more than 8 items a filter box is shown and filtering happens on the server
  (`HelmsmanWeb.Components.MenuList`). Arrow keys, Enter and Esc are handled by the
  `Hotkeys` hook; the popover carries `data-hm-menu`, `data-open` and `data-cancel`.
  """
  use Phoenix.Component
  use Gettext, backend: HelmsmanWeb.Gettext

  import HelmsmanWeb.CoreComponents, only: [icon: 1, kbd: 1]

  alias HelmsmanWeb.Components.{Actor, Brand}
  alias Phoenix.LiveView.JS

  @filter_threshold 8

  @doc "Number of items above which a filter box is shown."
  def filter_threshold, do: @filter_threshold

  @doc """
  JS command that opens the menu `id`. Focus goes to the filter box when there is one,
  otherwise to the menu itself, so the first ↓ selects the first item.
  """
  def open_menu(id, filter? \\ false) when is_binary(id), do: open_menu(%JS{}, id, filter?)

  def open_menu(%JS{} = js, id, filter?) do
    js
    |> JS.show(to: "##{id}-popover", display: "flex")
    |> JS.set_attribute({"data-open", ""}, to: "##{id}-popover")
    |> JS.set_attribute({"aria-expanded", "true"}, to: "##{id}-trigger")
    |> JS.focus(to: if(filter?, do: "##{id}-filter", else: "##{id}-popover"))
  end

  @doc "JS command that closes the menu `id` and returns focus to its trigger."
  def close_menu(js \\ %JS{}, id) do
    js
    |> JS.hide(to: "##{id}-popover")
    |> JS.remove_attribute("data-open", to: "##{id}-popover")
    |> JS.set_attribute({"aria-expanded", "false"}, to: "##{id}-trigger")
    |> JS.focus(to: "##{id}-trigger")
  end

  @doc """
  Renders a trigger button and its pop-up menu.

      <.dropdown id="row-1-menu" items={@items} label="更多操作">
        <:trigger><.icon name="lucide-ellipsis" /></:trigger>
      </.dropdown>
  """
  attr :id, :string, required: true
  attr :items, :list, required: true
  attr :label, :string, required: true, doc: "accessible name of the menu"
  attr :placement, :atom, default: :bottom, values: [:bottom, :top]
  attr :align, :atom, default: :start, values: [:start, :end]
  attr :trigger_class, :any, default: nil
  attr :class, :any, default: nil
  attr :popover_class, :any, default: "w-56"
  slot :trigger, required: true

  def dropdown(assigns) do
    assigns =
      assign(assigns,
        items: with_ids(assigns.items, assigns.id),
        filter?: filterable?(assigns.items)
      )

    ~H"""
    <div class={["relative inline-flex", @class]} style={"anchor-name: --hm-#{@id}"}>
      <button
        id={"#{@id}-trigger"}
        type="button"
        aria-haspopup="menu"
        aria-expanded="false"
        aria-controls={"#{@id}-popover"}
        aria-label={@label}
        class={[
          "inline-flex items-center gap-1.5 rounded-field text-fg hover:bg-hover",
          @trigger_class || "h-8 px-2"
        ]}
        phx-click={open_menu(@id, @filter?)}
      >
        {render_slot(@trigger)}
      </button>
      <div
        id={"#{@id}-popover"}
        data-hm-menu
        tabindex="-1"
        data-cancel={close_menu(@id)}
        phx-click-away={close_menu(@id)}
        style={"position-anchor: --hm-#{@id}"}
        class={[
          "hm-popover absolute z-40 hidden flex-col rounded-box border border-border",
          "bg-raised p-1 shadow-popover",
          @placement == :bottom && "top-full mt-1",
          @placement == :top && "bottom-full mb-1",
          @align == :start && "left-0",
          @align == :end && "right-0",
          @popover_class
        ]}
      >
        <.live_component
          :if={@filter?}
          module={HelmsmanWeb.Components.MenuList}
          id={"#{@id}-list"}
          menu_id={@id}
          label={@label}
          items={@items}
        />
        <.menu_items :if={!@filter?} menu_id={@id} label={@label} items={@items} />
      </div>
    </div>
    """
  end

  @doc false
  def filterable?(items),
    do: Enum.count(items, &(Map.get(&1, :type) != :divider)) > @filter_threshold

  # Stable DOM ids from the position in the full list, so a filtered list keeps the ids.
  defp with_ids(items, menu_id) do
    items
    |> Enum.with_index()
    |> Enum.map(fn
      {%{type: :divider} = item, _index} -> item
      {item, index} -> Map.put_new(item, :id, "#{menu_id}-item-#{index}")
    end)
  end

  @doc """
  The item Enter in the filter box selects: the first enabled item matching `query`
  (`nil` when there is none).
  """
  def first_selectable(items, query) do
    items
    |> filter_items(query)
    |> Enum.find(&(Map.get(&1, :type) != :divider and Map.get(&1, :disabled_reason) == nil))
  end

  @doc "Keeps the items whose label contains `query` (case-insensitive); drops dividers."
  def filter_items(items, query) do
    case String.trim(query || "") do
      "" ->
        items

      q ->
        q = String.downcase(q)

        Enum.filter(items, fn item ->
          Map.get(item, :type) != :divider and
            String.contains?(String.downcase(item.label), q)
        end)
    end
  end

  @doc false
  attr :menu_id, :string, required: true
  attr :label, :string, required: true
  attr :items, :list, required: true

  def menu_items(assigns) do
    assigns = assign(assigns, :rows, with_group_headings(assigns.items))

    ~H"""
    <div role="menu" aria-label={@label} id={"#{@menu_id}-menu"} class="flex flex-col">
      <p :if={@items == []} class="px-2 py-1.5 text-label text-fg-muted">
        {dgettext("ui", "没有匹配的选项")}
      </p>
      <%= for {row, index} <- Enum.with_index(@rows) do %>
        <div
          :if={row == :divider}
          role="separator"
          class="my-1 h-px bg-border"
          id={"#{@menu_id}-sep-#{index}"}
        />
        <div
          :if={match?({:group, _}, row)}
          role="presentation"
          class="px-2 pt-2 pb-1 text-micro font-medium uppercase tracking-wide text-fg-subtle"
        >
          {elem(row, 1)}
        </div>
        <.menu_item
          :if={is_map(row)}
          item={row}
          menu_id={@menu_id}
          dom_id={row.id}
        />
      <% end %>
    </div>
    """
  end

  defp with_group_headings(items) do
    {rows, _} =
      Enum.flat_map_reduce(items, nil, fn
        %{type: :divider}, group ->
          {[:divider], group}

        item, group ->
          case Map.get(item, :group) do
            ^group -> {[item], group}
            nil -> {[item], group}
            new -> {[{:group, new}, item], new}
          end
      end)

    rows
  end

  attr :item, :map, required: true
  attr :menu_id, :string, required: true
  attr :dom_id, :string, required: true

  defp menu_item(assigns) do
    item = assigns.item
    disabled? = Map.get(item, :disabled_reason) != nil
    close = close_menu(assigns.menu_id)

    assigns =
      assign(assigns,
        disabled?: disabled?,
        role: if(Map.has_key?(item, :checked), do: "menuitemradio", else: "menuitem"),
        click: if(!disabled?, do: select_js(item, close)),
        link: !disabled? && Enum.find([:navigate, :patch, :href], &Map.get(item, &1)),
        attrs: Map.get(item, :attrs, %{}),
        class: [
          "flex w-full min-h-8 items-center gap-2 rounded-field px-2 py-1.5 text-left text-body",
          "outline-none focus-visible:outline-none focus:bg-hover",
          if(disabled?,
            do: "cursor-not-allowed text-fg-subtle",
            else: [
              "cursor-pointer hover:bg-hover",
              if(Map.get(item, :danger), do: "text-danger-fg", else: "text-fg")
            ]
          )
        ]
      )

    ~H"""
    <.link
      :if={@link}
      id={@dom_id}
      role={@role}
      aria-checked={checked_attr(@item)}
      class={@class}
      phx-click={@click}
      method={@item[:method]}
      {Map.put(@attrs, @link, Map.fetch!(@item, @link))}
    >
      <.item_body item={@item} disabled?={false} />
    </.link>
    <button
      :if={!@link}
      id={@dom_id}
      type="button"
      role={@role}
      aria-checked={checked_attr(@item)}
      aria-disabled={@disabled? && "true"}
      aria-describedby={@disabled? && "#{@dom_id}-reason"}
      class={@class}
      phx-click={@click}
      {@attrs}
    >
      <.item_body item={@item} disabled?={@disabled?} dom_id={@dom_id} />
    </button>
    """
  end

  attr :item, :map, required: true
  attr :disabled?, :boolean, required: true
  attr :dom_id, :string, default: nil

  defp item_body(assigns) do
    ~H"""
    <.icon :if={@item[:icon]} name={@item.icon} class="size-4 shrink-0 text-fg-muted" />
    <Actor.actor_mark :if={@item[:actor]} actor={@item.actor} size={:xs} />
    <Brand.brand_icon
      :if={@item[:brand]}
      icon={if(@item.brand == :none, do: nil, else: @item.brand)}
      size={:xs}
    />
    <span class="flex min-w-0 flex-1 flex-col">
      <span class="truncate">{@item.label}</span>
      <span :if={@item[:description]} class="truncate text-caption text-fg-muted">
        {@item.description}
      </span>
      <span :if={@disabled?} id={"#{@dom_id}-reason"} class="text-caption text-fg-subtle">
        {@item.disabled_reason}
      </span>
    </span>
    <.kbd :if={@item[:shortcut]}>{@item.shortcut}</.kbd>
    <.icon :if={@item[:checked] == true} name="lucide-check" class="size-4 shrink-0 text-brand" />
    <.icon
      :if={@item[:checked] == :client}
      name="lucide-check"
      class="hm-client-check hidden size-4 shrink-0 text-brand"
    />
    """
  end

  defp checked_attr(item) do
    case Map.fetch(item, :checked) do
      {:ok, :client} -> nil
      {:ok, checked} -> to_string(checked == true)
      :error -> nil
    end
  end

  defp select_js(item, close) do
    case Map.get(item, :on_select) do
      %JS{} = js -> JS.concat(close, js)
      event when is_binary(event) -> JS.push(close, event, value: Map.get(item, :value, %{}))
      nil -> close
    end
  end
end
