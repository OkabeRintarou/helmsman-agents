defmodule HelmsmanWeb.Components.Layout do
  @moduledoc """
  Page-level layout pieces: `page_header/1`, `tabs/1`, `property_list/1`,
  `property_row/1` and `empty_state/1`, plus the drawer JS used on narrow screens.
  """
  use Phoenix.Component
  use Gettext, backend: HelmsmanWeb.Gettext

  import HelmsmanWeb.CoreComponents, only: [icon: 1, icon_button: 1, button: 1]

  alias Phoenix.LiveView.JS

  @doc "Opens the sidebar drawer (below `lg`)."
  def open_drawer(js \\ %JS{}) do
    js
    |> JS.add_class("hm-drawer-open", to: "#hm-sidebar")
    |> JS.show(to: "#hm-sidebar-backdrop")
    |> JS.set_attribute({"aria-expanded", "true"}, to: "#hm-drawer-toggle")
    |> JS.focus_first(to: "#hm-sidebar")
  end

  @doc "Closes the sidebar drawer."
  def close_drawer(js \\ %JS{}) do
    js
    |> JS.remove_class("hm-drawer-open", to: "#hm-sidebar")
    |> JS.hide(to: "#hm-sidebar-backdrop")
    |> JS.set_attribute({"aria-expanded", "false"}, to: "#hm-drawer-toggle")
  end

  @doc """
  48px page header: drawer button (narrow screens), breadcrumbs + title on the left,
  page actions on the right (at most one primary button).

      <.page_header title="BOS-12">
        <:crumb navigate={~p"/w/acme/projects/bos"}>BOS</:crumb>
        <:actions><.button variant="primary">开始</.button></:actions>
      </.page_header>
  """
  attr :title, :string, required: true
  attr :class, :any, default: nil

  slot :crumb do
    attr :navigate, :string
  end

  slot :leading, doc: "shown before the title (e.g. an identity's mark)"
  slot :actions

  def page_header(assigns) do
    ~H"""
    <header class={[
      "flex h-12 flex-none items-center gap-2 border-b border-border px-4",
      @class
    ]}>
      <.icon_button
        id="hm-drawer-toggle"
        icon="lucide-menu"
        label={dgettext("ui", "打开导航")}
        tooltip={false}
        class="lg:hidden -ml-1"
        aria-controls="hm-sidebar"
        aria-expanded="false"
        phx-click={open_drawer()}
      />
      <nav :if={@crumb != []} aria-label={dgettext("ui", "面包屑")} class="flex min-w-0 items-center">
        <ol class="flex min-w-0 items-center gap-1 text-body text-fg-muted">
          <li :for={crumb <- @crumb} class="flex min-w-0 items-center gap-1">
            <.link :if={crumb[:navigate]} navigate={crumb.navigate} class="truncate hover:text-fg">
              {render_slot(crumb)}
            </.link>
            <span :if={!crumb[:navigate]} class="truncate">{render_slot(crumb)}</span>
            <.icon name="lucide-chevron-right" class="size-3.5 text-fg-subtle" />
          </li>
        </ol>
      </nav>
      <div :if={@leading != []} class="flex flex-none items-center">{render_slot(@leading)}</div>
      <h1 class="min-w-0 flex-1 truncate text-body font-semibold text-fg">{@title}</h1>
      <div :if={@actions != []} class="flex flex-none items-center gap-2">
        {render_slot(@actions)}
      </div>
    </header>
    """
  end

  @doc """
  URL-driven tabs rendered as navigation links (`patch` by default). The active tab
  gets `aria-current="page"`.

      <.tabs label="任务视图">
        <:tab patch="?tab=open" active={@tab == "open"} count={12}>进行中</:tab>
      </.tabs>
  """
  attr :label, :string, required: true
  attr :class, :any, default: nil

  slot :tab, required: true do
    attr :patch, :string
    attr :navigate, :string
    attr :active, :boolean
    attr :count, :integer
  end

  def tabs(assigns) do
    ~H"""
    <nav aria-label={@label} class={["flex items-center gap-4 border-b border-border", @class]}>
      <.link
        :for={tab <- @tab}
        patch={tab[:patch]}
        navigate={tab[:navigate]}
        aria-current={tab[:active] && "page"}
        class={[
          "-mb-px inline-flex h-9 items-center gap-1.5 border-b-2 text-body",
          if(tab[:active],
            do: "border-brand font-medium text-fg",
            else: "border-transparent text-fg-muted hover:text-fg"
          )
        ]}
      >
        {render_slot(tab)}
        <span
          :if={tab[:count]}
          class="rounded-badge bg-hover px-1.5 text-micro leading-4 text-fg-muted"
        >
          {tab.count}
        </span>
      </.link>
    </nav>
    """
  end

  @doc """
  Key/value rows (labels in fg-muted with a fixed width, 32px rows).

      <.property_list>
        <.property_row label="负责人"><.actor_chip actor={@assignee} /></.property_row>
        <.property_row label="截止日期" value={@task.due_on} />
      </.property_list>
  """
  attr :class, :any, default: nil
  slot :inner_block, required: true

  def property_list(assigns) do
    ~H"""
    <dl class={["flex flex-col", @class]}>{render_slot(@inner_block)}</dl>
    """
  end

  @doc """
  One property row. Empty values (no inner block and `value` nil or "") show
  `placeholder` or a fg-subtle "—". `editable` adds a hover affordance.
  """
  attr :label, :string, required: true
  attr :value, :any, default: nil
  attr :placeholder, :string, default: nil
  attr :editable, :boolean, default: false
  attr :rest, :global
  slot :inner_block

  def property_row(assigns) do
    assigns =
      assign(assigns, :empty?, assigns.inner_block == [] and assigns.value in [nil, ""])

    ~H"""
    <div class="grid min-h-8 grid-cols-[7.5rem_1fr] items-center gap-2" {@rest}>
      <dt class="truncate text-label text-fg-muted">{@label}</dt>
      <dd class={[
        "group flex min-w-0 items-center gap-1 rounded-field text-body",
        @editable && "-mx-1.5 cursor-pointer px-1.5 py-1 hover:bg-hover"
      ]}>
        <span :if={@empty?} class="text-fg-subtle">{@placeholder || "—"}</span>
        <span :if={!@empty? and @inner_block == []} class="truncate text-fg">{@value}</span>
        {render_slot(@inner_block)}
        <.icon
          :if={@editable}
          name="lucide-pencil"
          class="ml-auto size-3.5 text-fg-subtle opacity-0 group-hover:opacity-100"
        />
      </dd>
    </div>
    """
  end

  @doc """
  Empty state. `kind={:empty}` ("还没有数据") takes a create action in the `:action`
  slot; `kind={:filtered}` shows "没有符合条件的结果" and a "清除筛选" button that runs
  `on_clear` (usually a `JS.patch/1` to the unfiltered URL).
  """
  attr :kind, :atom, default: :empty, values: [:empty, :filtered]
  attr :icon, :string, default: "lucide-inbox"
  attr :title, :string, default: nil
  attr :description, :string, default: nil
  attr :on_clear, :any, default: nil
  attr :class, :any, default: nil
  slot :action

  def empty_state(assigns) do
    ~H"""
    <div class={["flex flex-col items-center justify-center gap-2 px-6 py-12 text-center", @class]}>
      <span class="mb-1 inline-flex size-10 items-center justify-center rounded-full bg-hover">
        <.icon
          name={if(@kind == :filtered, do: "lucide-search-x", else: @icon)}
          class="size-5 text-fg-muted"
        />
      </span>
      <p class="text-title font-medium text-fg">
        {@title ||
          if(@kind == :filtered,
            do: dgettext("ui", "没有符合条件的结果"),
            else: dgettext("ui", "还没有数据")
          )}
      </p>
      <p :if={@description} class="max-w-sm text-body text-fg-muted">{@description}</p>
      <div :if={@kind == :empty and @action != []} class="mt-2">{render_slot(@action)}</div>
      <div :if={@kind == :filtered} class="mt-2">
        <.button icon="lucide-funnel-x" phx-click={@on_clear}>{dgettext("ui", "清除筛选")}</.button>
      </div>
    </div>
    """
  end
end
