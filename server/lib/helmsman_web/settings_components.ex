defmodule HelmsmanWeb.SettingsComponents do
  @moduledoc """
  Frame of the workspace settings pages (add-workspace-settings-ui D5): the app layout
  with the 设置 breadcrumb, the current tab's title and the settings tabs.
  """
  use Phoenix.Component
  use Gettext, backend: HelmsmanWeb.Gettext

  import HelmsmanWeb.Components.Layout, only: [page_header: 1, tabs: 1]

  alias HelmsmanWeb.{Layouts, Settings}

  attr :tab, :atom, required: true, doc: "id of the current tab"
  attr :flash, :map, required: true
  attr :current_scope, :map, required: true
  attr :shell, :map, required: true
  slot :actions
  slot :inner_block, required: true

  def settings_page(assigns) do
    tabs = Settings.tabs(assigns.current_scope)
    current = Enum.find(tabs, &(&1.id == assigns.tab))
    assigns = assign(assigns, tabs: tabs, current: current)

    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} shell={@shell}>
      <:header>
        <.page_header title={@current.label}>
          <:crumb navigate={hd(@tabs).path}>{dgettext("ui", "设置")}</:crumb>
          <:actions :if={@actions != []}>{render_slot(@actions)}</:actions>
        </.page_header>
      </:header>
      <div class="mx-auto w-full max-w-5xl px-4 pb-10 sm:px-6">
        <.tabs label={dgettext("ui", "设置")} class="mb-6">
          <:tab :for={tab <- @tabs} navigate={tab.path} active={tab.id == @tab}>{tab.label}</:tab>
        </.tabs>
        {render_slot(@inner_block)}
      </div>
    </Layouts.app>
    """
  end

  @doc "A titled section of a settings page."
  attr :id, :string, default: nil
  attr :title, :string, required: true
  attr :description, :string, default: nil
  attr :danger, :boolean, default: false
  attr :class, :any, default: nil
  slot :actions
  slot :inner_block, required: true

  def settings_section(assigns) do
    ~H"""
    <section
      id={@id}
      aria-labelledby={@id && "#{@id}-title"}
      class={[
        "mb-8 rounded-box border bg-surface",
        if(@danger, do: "border-danger", else: "border-border"),
        @class
      ]}
    >
      <header class="flex items-center justify-between gap-2 border-b border-border px-4 py-3">
        <div class="min-w-0">
          <h2
            id={@id && "#{@id}-title"}
            class={["text-title font-semibold", if(@danger, do: "text-danger-fg", else: "text-fg")]}
          >
            {@title}
          </h2>
          <p :if={@description} class="text-caption text-fg-muted">{@description}</p>
        </div>
        <div :if={@actions != []} class="flex flex-none items-center gap-2">
          {render_slot(@actions)}
        </div>
      </header>
      <div class="px-4 py-3">{render_slot(@inner_block)}</div>
    </section>
    """
  end
end
