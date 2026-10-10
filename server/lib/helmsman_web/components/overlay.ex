defmodule HelmsmanWeb.Components.Overlay do
  @moduledoc """
  Modal layers (design D5c): `overlay/1` is the shared base for `side_panel/1`,
  `confirm_dialog/1` and `modal/1`.

  * Content is teleported with `<.portal>` into `#hm-overlays`, a sibling of `#hm-shell`.
  * Opening: remember the focused element (`hm:overlay-open`) → show → `inert` on the
    layer underneath (`#hm-shell`, or the overlay given in `stack_on`) → focus the
    initial element.
  * Closing (the JS stored in `data-cancel`, also run by `Hotkeys` on Esc): hide →
    remove `inert` from the layer underneath → restore focus (`hm:overlay-close`).

  Focus is remembered by `app.js` rather than `JS.push_focus/0`, which records the
  element the command runs on — wrong when an overlay is opened by a keyboard shortcut
  or by the URL (`phx-mounted`).
  * `Hotkeys` treats `[data-hm-overlay][data-open]:not([inert])` as the top-most layer.

  Overlays are opened by the server (`show={true}`, e.g. driven by a URL parameter) or on
  the client with `open_overlay/2`.
  """
  use Phoenix.Component
  use Gettext, backend: HelmsmanWeb.Gettext

  import HelmsmanWeb.CoreComponents, only: [icon_button: 1]

  alias Phoenix.LiveView.JS

  @doc """
  JS command that opens the overlay `id`. Options: `:focus` (selector of the initially
  focused element), `:stack_on` (id of the overlay underneath), `:kind` (`:panel`).
  """
  def open_overlay(id, opts \\ [])
  def open_overlay(id, opts) when is_binary(id), do: open_overlay(%JS{}, id, opts)
  def open_overlay(%JS{} = js, id) when is_binary(id), do: open_overlay(js, id, [])

  def open_overlay(%JS{} = js, id, opts) do
    below = Keyword.get(opts, :stack_on)
    focus = Keyword.get(opts, :focus)

    js
    |> JS.dispatch("hm:overlay-open", to: "##{id}")
    |> JS.set_attribute({"data-open", ""}, to: "##{id}")
    |> JS.show(to: "##{id}")
    |> JS.show(
      to: "##{id}-backdrop",
      time: 150,
      transition: {"transition-opacity ease-out duration-150", "opacity-0", "opacity-100"}
    )
    |> JS.show(
      to: "##{id}-container",
      time: 150,
      display: "flex",
      transition: transition(Keyword.get(opts, :kind, :dialog), :in)
    )
    |> JS.set_attribute({"inert", ""}, to: below_selector(below))
    |> focus_initial(id, focus)
  end

  @doc "JS command that closes the overlay `id` on the client (same options as `open_overlay/3`)."
  def close_overlay(id, opts \\ [])
  def close_overlay(id, opts) when is_binary(id), do: close_overlay(%JS{}, id, opts)
  def close_overlay(%JS{} = js, id) when is_binary(id), do: close_overlay(js, id, [])

  def close_overlay(%JS{} = js, id, opts) do
    below = Keyword.get(opts, :stack_on)

    js
    |> JS.remove_attribute("data-open", to: "##{id}")
    |> JS.hide(
      to: "##{id}-container",
      time: 120,
      transition: transition(Keyword.get(opts, :kind, :dialog), :out)
    )
    |> JS.hide(
      to: "##{id}-backdrop",
      time: 120,
      transition: {"transition-opacity ease-in duration-120", "opacity-100", "opacity-0"}
    )
    |> JS.hide(to: "##{id}", time: 120)
    |> JS.remove_attribute("inert", to: below_selector(below))
    |> JS.dispatch("hm:overlay-close", to: "##{id}")
  end

  defp below_selector(nil), do: "#hm-shell"
  defp below_selector(id), do: "##{id}"

  defp focus_initial(js, id, nil), do: JS.focus_first(js, to: "##{id}-content")
  defp focus_initial(js, _id, selector), do: JS.focus(js, to: selector)

  defp transition(:panel, :in),
    do: {"transition-transform ease-out duration-150", "translate-x-full", "translate-x-0"}

  defp transition(:panel, :out),
    do: {"transition-transform ease-in duration-120", "translate-x-0", "translate-x-full"}

  defp transition(_, :in),
    do: {"transition-all ease-out duration-120", "opacity-0 scale-95", "opacity-100 scale-100"}

  defp transition(_, :out),
    do: {"transition-all ease-in duration-120", "opacity-100 scale-100", "opacity-0 scale-95"}

  @doc """
  Base modal layer. Prefer `side_panel/1`, `confirm_dialog/1` or `modal/1`.

  Two modes:

  * **server-controlled** (`show={true | false}`): rendered only while `show` is true; it
    opens on mount and closes in `phx-remove`. Dismissing runs `on_cancel` only (e.g. a
    `JS.patch/1` removing the URL parameter, or a `JS.push/1`), so `on_cancel` is required.
  * **client-controlled** (`show` omitted): always rendered and hidden; open it with
    `open_overlay/2` (or `JS.exec("data-show", to: "#id")`); dismissing closes it on the
    client and then runs `on_cancel`.
  """
  attr :id, :string, required: true
  attr :show, :boolean, default: nil
  attr :kind, :atom, default: :dialog, values: [:panel, :dialog]
  attr :role, :string, default: "dialog", values: ~w(dialog alertdialog)
  attr :on_cancel, JS, default: %JS{}, doc: "JS run when the overlay is dismissed"
  attr :dirty, :boolean, default: false, doc: "when true a backdrop click does not close"
  attr :stack_on, :string, default: nil, doc: "id of the overlay this one is stacked on"
  attr :focus, :string, default: nil, doc: "selector of the initially focused element"
  attr :labelledby, :string, default: nil
  attr :describedby, :string, default: nil
  attr :container_class, :any, default: nil
  attr :position_class, :any, default: nil
  attr :rest, :global
  slot :inner_block, required: true

  def overlay(assigns) do
    opts = [kind: assigns.kind, stack_on: assigns.stack_on, focus: assigns.focus]
    close = close_overlay(assigns.id, opts)

    cancel =
      if is_nil(assigns.show),
        do: JS.concat(close, assigns.on_cancel),
        else: assigns.on_cancel

    assigns =
      assign(assigns,
        cancel: cancel,
        close: close,
        open: open_overlay(assigns.id, opts),
        render?: assigns.show != false
      )

    ~H"""
    <.portal id={"#{@id}-portal"} target="#hm-overlays">
      <div
        :if={@render?}
        id={@id}
        data-hm-overlay
        data-cancel={@cancel}
        data-show={@open}
        phx-mounted={@show && @open}
        phx-remove={@show && @close}
        role={@role}
        aria-modal="true"
        aria-labelledby={@labelledby || "#{@id}-title"}
        aria-describedby={@describedby}
        class={["relative hidden", if(@stack_on, do: "z-[60]", else: "z-50")]}
        {@rest}
      >
        <div
          id={"#{@id}-backdrop"}
          class="fixed inset-0 bg-scrim hidden"
          aria-hidden="true"
          phx-click={if(!@dirty, do: @cancel)}
        />
        <div class={["fixed inset-0 pointer-events-none flex", @position_class]}>
          <.focus_wrap
            id={"#{@id}-container"}
            class={["pointer-events-auto hidden flex-col bg-raised shadow-overlay", @container_class]}
          >
            <div id={"#{@id}-content"} class="contents">
              {render_slot(@inner_block, @cancel)}
            </div>
          </.focus_wrap>
        </div>
      </div>
    </.portal>
    """
  end

  @doc """
  Right-hand side panel for every interaction that needs input (create, edit, reasons,
  evidence, manual runs …).

  * `width`: `:standard` 480px or `:wide` 640px; full width on narrow screens.
  * `dirty`: unsaved input — a backdrop click no longer closes the panel.
  * `patch_on_close`: URL to patch to when closed (for panels driven by `?panel=…`).
  * `:error` slot is shown at the top of the body (e.g. a failed submit).
  * `:footer` slot is pinned to the bottom (secondary actions left, primary right).

  The inner block receives the cancel JS, so a "取消" button can use `phx-click={cancel}`.
  """
  attr :id, :string, required: true
  attr :show, :boolean, default: nil
  attr :title, :string, required: true
  attr :width, :atom, default: :standard, values: [:standard, :wide]
  attr :dirty, :boolean, default: false
  attr :patch_on_close, :string, default: nil
  attr :on_cancel, JS, default: %JS{}
  slot :inner_block, required: true
  slot :error
  slot :footer

  def side_panel(assigns) do
    assigns = assign(assigns, :on_cancel, with_patch(assigns.on_cancel, assigns.patch_on_close))

    ~H"""
    <.overlay
      :let={cancel}
      id={@id}
      show={@show}
      kind={:panel}
      dirty={@dirty}
      on_cancel={@on_cancel}
      position_class="justify-end"
      container_class={[
        "h-full w-full border-l border-border",
        if(@width == :wide, do: "sm:w-[640px]", else: "sm:w-[480px]")
      ]}
    >
      <header class="flex h-12 flex-none items-center justify-between gap-2 border-b border-border px-4">
        <h2 id={"#{@id}-title"} class="truncate text-title font-semibold text-fg">{@title}</h2>
        <.icon_button icon="lucide-x" label={dgettext("ui", "关闭")} phx-click={cancel} tooltip={false} />
      </header>
      <div class="min-h-0 flex-1 overflow-y-auto px-4 py-4">
        <div
          :if={@error != []}
          role="alert"
          class="mb-4 flex items-start gap-2 rounded-field border border-danger tint-danger px-3 py-2 text-body text-danger-fg"
        >
          {render_slot(@error)}
        </div>
        {render_slot(@inner_block, cancel)}
      </div>
      <footer
        :if={@footer != []}
        class="flex flex-none items-center justify-between gap-2 border-t border-border px-4 py-3"
      >
        {render_slot(@footer, cancel)}
      </footer>
    </.overlay>
    """
  end

  @doc """
  Centered confirmation dialog (`role="alertdialog"`). Never use the browser's `confirm`.

  * `danger`: destructive — danger confirm button and initial focus on "取消".
    Otherwise the primary confirm button gets the initial focus.
  * `on_confirm` / `confirm_value`: event (or JS) of the main action.
  * `:secondary_action` slot: an optional second affirmative button (e.g. "暂不开始")
    with its own `event` / `value`.
  * `stack_on`: id of the overlay underneath (e.g. the side panel the dialog opened from).
  * Ctrl/⌘+Enter (handled by `Hotkeys`) clicks `[data-confirm-primary]`.
  """
  attr :id, :string, required: true
  attr :show, :boolean, default: nil
  attr :title, :string, required: true
  attr :danger, :boolean, default: false
  attr :confirm_label, :string, required: true
  attr :cancel_label, :string, default: nil
  attr :on_confirm, :any, required: true, doc: "event name or %JS{}"
  attr :confirm_value, :map, default: %{}
  attr :on_cancel, JS, default: %JS{}
  attr :stack_on, :string, default: nil
  attr :target, :any, default: nil, doc: "phx-target for the events"
  slot :inner_block, doc: "one sentence describing the consequence"

  slot :secondary_action do
    attr :label, :string, required: true
    attr :event, :any, required: true
    attr :value, :map
  end

  def confirm_dialog(assigns) do
    focus = if assigns.danger, do: "##{assigns.id}-cancel", else: "##{assigns.id}-confirm"
    assigns = assign(assigns, :focus, focus)

    ~H"""
    <.overlay
      :let={cancel}
      id={@id}
      show={@show}
      role="alertdialog"
      on_cancel={@on_cancel}
      stack_on={@stack_on}
      focus={@focus}
      describedby={"#{@id}-description"}
      position_class="items-center justify-center p-4"
      container_class="w-full max-w-[440px] rounded-box border border-border"
    >
      <div class="px-5 pt-5">
        <h2 id={"#{@id}-title"} class="text-title font-semibold text-fg">{@title}</h2>
        <p id={"#{@id}-description"} class="mt-2 text-body text-fg-muted">
          {render_slot(@inner_block)}
        </p>
      </div>
      <div class="flex items-center justify-end gap-2 px-5 py-4">
        <button
          id={"#{@id}-cancel"}
          type="button"
          autofocus={@danger}
          class={dialog_button_class(:secondary)}
          phx-click={cancel}
        >
          {@cancel_label || dgettext("ui", "取消")}
        </button>
        <button
          :for={action <- @secondary_action}
          type="button"
          class={dialog_button_class(:secondary)}
          phx-click={confirm_js(action.event, Map.get(action, :value, %{}), cancel)}
          phx-target={@target}
        >
          {action.label}
        </button>
        <button
          id={"#{@id}-confirm"}
          type="button"
          autofocus={!@danger}
          data-confirm-primary
          class={dialog_button_class(if(@danger, do: :danger, else: :primary))}
          phx-click={confirm_js(@on_confirm, @confirm_value, cancel)}
          phx-target={@target}
        >
          {@confirm_label}
        </button>
      </div>
    </.overlay>
    """
  end

  defp confirm_js(%JS{} = js, _value, cancel), do: JS.concat(js, cancel)
  defp confirm_js(event, value, cancel), do: JS.push(cancel, event, value: value)

  defp dialog_button_class(variant) do
    [
      "btn h-8 px-3 shadow-none rounded-field text-body font-medium",
      case variant do
        :primary -> "btn-primary border-transparent"
        :danger -> "btn-error border-transparent"
        :secondary -> "bg-surface text-fg border-border-strong hover:bg-hover"
      end
    ]
  end

  @doc """
  Centered dialog for large read-only views (e.g. a run log), optionally bound to a URL
  parameter: open it with `show={@params["run"] != nil}` and pass `patch_on_close`.

  Sizes: `:sm` 440px, `:md` 640px, `:lg` 960px, `:xl` 960px × 85vh. The body scrolls;
  title bar and `:footer` stay fixed.
  """
  attr :id, :string, required: true
  attr :show, :boolean, default: nil
  attr :title, :string, required: true
  attr :size, :atom, default: :md, values: [:sm, :md, :lg, :xl]
  attr :patch_on_close, :string, default: nil
  attr :on_cancel, JS, default: %JS{}
  slot :inner_block, required: true
  slot :footer

  def modal(assigns) do
    assigns = assign(assigns, :on_cancel, with_patch(assigns.on_cancel, assigns.patch_on_close))

    ~H"""
    <.overlay
      :let={cancel}
      id={@id}
      show={@show}
      on_cancel={@on_cancel}
      position_class="items-center justify-center p-4"
      container_class={[
        "w-full max-h-[85vh] rounded-box border border-border",
        modal_size(@size)
      ]}
    >
      <header class="flex h-12 flex-none items-center justify-between gap-2 border-b border-border px-4">
        <h2 id={"#{@id}-title"} class="truncate text-title font-semibold text-fg">{@title}</h2>
        <.icon_button icon="lucide-x" label={dgettext("ui", "关闭")} phx-click={cancel} tooltip={false} />
      </header>
      <div class="min-h-0 flex-1 overflow-y-auto p-4">{render_slot(@inner_block, cancel)}</div>
      <footer
        :if={@footer != []}
        class="flex flex-none items-center justify-end gap-2 border-t border-border px-4 py-3"
      >
        {render_slot(@footer, cancel)}
      </footer>
    </.overlay>
    """
  end

  defp modal_size(:sm), do: "sm:max-w-[440px]"
  defp modal_size(:md), do: "sm:max-w-[640px]"
  defp modal_size(:lg), do: "sm:max-w-[960px]"
  defp modal_size(:xl), do: "sm:max-w-[960px] sm:h-[85vh]"

  defp with_patch(js, nil), do: js
  defp with_patch(js, path), do: JS.patch(js, path)
end
