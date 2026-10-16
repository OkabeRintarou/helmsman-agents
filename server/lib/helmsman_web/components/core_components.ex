defmodule HelmsmanWeb.CoreComponents do
  @moduledoc """
  Core UI building blocks: icons, buttons, form controls, tooltips, key hints
  and flash notices.

  Visual rules live in `assets/css/app.css` (tokens and themes, design D1–D4).
  daisyUI classes may only appear in this module and in `HelmsmanWeb.Components.*`;
  pages compose these components instead (checked by `mix helmsman.check_ui_classes`).
  All user-facing copy goes through the `"ui"` gettext domain.
  """
  use Phoenix.Component
  use Gettext, backend: HelmsmanWeb.Gettext

  alias Phoenix.HTML.Form
  alias Phoenix.LiveView.JS

  ## Icons

  @doc """
  Renders a [Lucide](https://lucide.dev) icon from the `:lucide` dependency.

  Decorative by default (`aria-hidden`); pass `label` to expose it as an image.

      <.icon name="lucide-bot" />
      <.icon name="lucide-circle-check" class="size-3.5 text-success" label="已验收" />
  """
  attr :name, :string, required: true

  attr :class, :any,
    default: "size-4",
    doc: "16px by default; use `size-3.5` (14px) in compact places"

  attr :label, :string, default: nil, doc: "accessible name; omit for decorative icons"
  attr :rest, :global

  def icon(%{name: "lucide-" <> _} = assigns) do
    ~H"""
    <span
      class={[@name, @class]}
      aria-hidden={if(@label, do: nil, else: "true")}
      role={@label && "img"}
      aria-label={@label}
      {@rest}
    />
    """
  end

  ## Buttons

  @variants %{
    "primary" => "btn-primary border-transparent",
    "secondary" => "bg-surface text-fg border-border-strong hover:bg-hover",
    "ghost" =>
      "btn-ghost bg-transparent border-transparent text-fg-muted hover:bg-hover hover:text-fg",
    "danger" => "btn-error border-transparent",
    "link" =>
      "btn-link h-auto min-h-0 px-0 bg-transparent border-transparent text-brand-fg hover:underline"
  }

  @sizes %{"xs" => "h-6 px-2 text-caption", "sm" => "h-7 px-2.5 text-label"}
  @sizes Map.merge(@sizes, %{"md" => "h-8 px-3 text-body", "lg" => "h-9 px-4 text-body"})
  @link_attrs [:href, :navigate, :patch, :"phx-click"]
  @icon_sizes %{"xs" => "size-6", "sm" => "size-7", "md" => "size-8", "lg" => "size-9"}

  @doc """
  Renders a button (or a link styled as a button when `href`, `navigate` or `patch` is given).

  * Variants: `primary` (at most one per page header or panel), `secondary` (default),
    `ghost`, `danger`, `link`. Sizes: `xs` 24px, `sm` 28px, `md` 32px (default), `lg` 36px.
  * `disabled_reason` keeps the button focusable (`aria-disabled`) and shows the reason as a
    tooltip linked through `aria-describedby`. Navigation and `phx-click` are dropped and
    `app.js` cancels clicks and form submits from such buttons (`data-hm-disabled`),
    including implicit Enter submission when it is a form's default button.
  * Inside a form being submitted LiveView disables the button; it then shows a spinner and
    `app.js` sets `aria-busy="true"` until the submit is acknowledged.

      <.button variant="primary" type="submit" icon="lucide-plus">新建 <:kbd>C</:kbd></.button>
  """
  attr :id, :string, default: nil
  attr :type, :string, default: "button"
  attr :variant, :string, default: "secondary", values: ~w(primary secondary ghost danger link)
  attr :size, :string, default: "md", values: ~w(xs sm md lg)
  attr :icon, :string, default: nil, doc: "leading Lucide icon"
  attr :disabled, :boolean, default: false
  attr :disabled_reason, :string, default: nil
  attr :class, :any, default: nil
  attr :rest, :global, include: ~w(href navigate patch method download name value form)
  slot :inner_block, required: true
  slot :kbd, doc: "shortcut hint shown after the label"

  def button(assigns) do
    assigns
    |> assign(:icon_only, false)
    |> assign(:label, nil)
    |> render_button()
  end

  @doc """
  A square button containing only an icon. `label` is required and becomes the
  accessible name and the tooltip.

      <.icon_button icon="lucide-x" label="关闭" variant="ghost" phx-click={...} />
  """
  attr :id, :string, default: nil
  attr :type, :string, default: "button"
  attr :icon, :string, required: true
  attr :label, :string, required: true
  attr :variant, :string, default: "ghost", values: ~w(primary secondary ghost danger)
  attr :size, :string, default: "md", values: ~w(xs sm md lg)
  attr :disabled, :boolean, default: false
  attr :disabled_reason, :string, default: nil
  attr :tooltip, :boolean, default: true
  attr :class, :any, default: nil
  attr :rest, :global, include: ~w(href navigate patch method download name value form)

  def icon_button(assigns) do
    assigns
    |> assign(:icon_only, true)
    |> assign(:inner_block, [])
    |> assign(:kbd, [])
    |> render_button()
  end

  defp render_button(%{disabled_reason: reason, id: nil}) when is_binary(reason) do
    raise ArgumentError, "<.button> with disabled_reason needs an id (for aria-describedby)"
  end

  defp render_button(assigns) do
    reason = assigns.disabled_reason
    inert? = assigns.disabled || reason != nil
    link? = not inert? and Enum.any?(~w(href navigate patch)a, &assigns.rest[&1])

    assigns =
      assign(assigns,
        rest: if(inert?, do: Map.drop(assigns.rest, @link_attrs), else: assigns.rest),
        link?: link?,
        tip: reason || icon_tip(assigns),
        tip_id: reason && "#{assigns.id}-reason",
        class: button_class(assigns, inert?)
      )

    ~H"""
    <span class={["inline-flex", @tip && "hm-tooltip-host relative"]}>
      <.link :if={@link?} id={@id} class={@class} aria-label={@label} {@rest}>
        <.button_content {assigns} />
      </.link>
      <button
        :if={!@link?}
        id={@id}
        type={@type}
        class={@class}
        disabled={@disabled}
        aria-disabled={@disabled_reason && "true"}
        data-hm-disabled={@disabled_reason && ""}
        aria-label={@label}
        aria-describedby={@disabled_reason && @tip_id}
        data-hm-busy
        {@rest}
      >
        <.button_content {assigns} />
      </button>
      <span
        :if={@tip}
        id={@tip_id}
        role={@tip_id && "tooltip"}
        aria-hidden={!@tip_id && "true"}
        class={tooltip_class(:bottom)}
      >
        {@tip}
      </span>
    </span>
    """
  end

  defp icon_tip(%{icon_only: true, tooltip: true, label: label}), do: label
  defp icon_tip(_assigns), do: nil

  defp button_class(assigns, inert?) do
    [
      "btn shadow-none font-medium gap-1.5 rounded-field whitespace-nowrap",
      Map.fetch!(@variants, assigns.variant),
      if(assigns.icon_only,
        do: [Map.fetch!(@icon_sizes, assigns.size), "p-0"],
        else: Map.fetch!(@sizes, assigns.size)
      ),
      inert? &&
        "cursor-not-allowed bg-hover text-fg-subtle border-transparent hover:bg-hover hover:text-fg-subtle",
      assigns.class
    ]
  end

  defp button_content(assigns) do
    ~H"""
    <.icon
      name="lucide-loader-circle"
      class="size-4 hidden phx-submit-loading:inline-block motion-safe:animate-spin"
    />
    <.icon
      :if={@icon}
      name={@icon}
      class={["size-4", @icon_only && "phx-submit-loading:hidden"]}
    />
    {render_slot(@inner_block)}
    <span :if={@kbd != []} class="ml-1 inline-flex gap-0.5 opacity-80">{render_slot(@kbd)}</span>
    """
  end

  ## Tooltip

  @doc """
  Wraps a trigger with a short plain-text tooltip (pure CSS: shown after 300ms hover,
  immediately on keyboard focus). Never put the only copy of important information
  in a tooltip — also expose it as accessible text.

      <.tooltip id="sync-tip" text="同步中"><.icon name="lucide-refresh-cw" /></.tooltip>
  """
  attr :id, :string,
    default: nil,
    doc: "id of the tooltip element (for aria-describedby); without it the tooltip is aria-hidden"

  attr :text, :string, required: true
  attr :placement, :atom, default: :bottom, values: [:top, :bottom, :right]
  attr :class, :any, default: nil
  slot :inner_block, required: true

  def tooltip(assigns) do
    ~H"""
    <span class={["hm-tooltip-host relative inline-flex", @class]}>
      {render_slot(@inner_block)}
      <span
        id={@id}
        role={@id && "tooltip"}
        aria-hidden={!@id && "true"}
        class={tooltip_class(@placement)}
      >
        {@text}
      </span>
    </span>
    """
  end

  @doc false
  def tooltip_class(placement) do
    [
      "hm-tooltip pointer-events-none absolute z-50 w-max max-w-64 whitespace-normal rounded-badge px-2 py-1",
      "bg-fg text-surface text-caption font-normal shadow-popover",
      case placement do
        :top -> "bottom-full left-1/2 -translate-x-1/2 mb-1.5"
        :bottom -> "top-full left-1/2 -translate-x-1/2 mt-1.5"
        :right -> "left-full top-1/2 -translate-y-1/2 ml-2"
      end
    ]
  end

  ## Keyboard hints

  @doc """
  Shows a key combination. `mod` renders both `⌘` and `Ctrl`; CSS shows the one
  matching `<html data-platform>`.

      <.kbd mod>K</.kbd>
  """
  attr :mod, :boolean, default: false, doc: "prefix with the platform modifier (⌘ / Ctrl)"
  attr :class, :any, default: nil
  slot :inner_block, required: true

  def kbd(assigns) do
    ~H"""
    <kbd class={[
      "kbd kbd-xs h-[18px] min-w-[18px] px-1 rounded-badge border-border-strong bg-surface",
      "font-mono text-micro text-fg-muted shadow-none",
      @class
    ]}>
      <span :if={@mod} class="hm-kbd-mac">⌘</span><span :if={@mod} class="hm-kbd-other">Ctrl+</span>{render_slot(
        @inner_block
      )}
    </kbd>
    """
  end

  ## Form controls

  @doc """
  Renders a form control with label, help text and errors.

  Types: `text` (and other HTML input types), `textarea`, `select`, `checkbox`,
  `switch`, `radio` and `hidden`. Errors are only shown once the field was used
  (`Phoenix.Component.used_input?/1`) and are linked via `aria-describedby`;
  the control gets `aria-invalid="true"`.

  `layout={:row}` renders label on the left and the control on the right
  (settings pages).

      <.input field={@form[:title]} label="标题" help="一句话说明" />
      <.input field={@form[:notify]} type="switch" label="通知" layout={:row} />
  """
  attr :id, :any, default: nil
  attr :name, :any
  attr :label, :string, default: nil
  attr :help, :string, default: nil
  attr :value, :any

  attr :type, :string,
    default: "text",
    values: ~w(checkbox color date datetime-local email file month number password
               search select switch radio tel text textarea time url week hidden)

  attr :layout, :atom, default: :stack, values: [:stack, :row]
  attr :field, Phoenix.HTML.FormField, doc: "a form field struct, e.g. @form[:title]"
  attr :errors, :list, default: []
  attr :checked, :boolean, doc: "the checked flag for checkbox and switch inputs"
  attr :prompt, :string, default: nil, doc: "the prompt for select inputs"
  attr :options, :list, doc: "options for select and radio inputs"
  attr :multiple, :boolean, default: false
  attr :class, :any, default: nil, doc: "extra classes for the control"

  attr :rest, :global,
    include: ~w(accept autocomplete capture cols disabled form list max maxlength min minlength
                multiple pattern placeholder readonly required rows size step phx-debounce)

  def input(%{field: %Phoenix.HTML.FormField{} = field} = assigns) do
    errors = if Phoenix.Component.used_input?(field), do: field.errors, else: []

    assigns
    |> assign(field: nil, id: assigns.id || field.id)
    |> assign(:errors, Enum.map(errors, &translate_error/1))
    |> assign_new(:name, fn -> if assigns.multiple, do: field.name <> "[]", else: field.name end)
    |> assign_new(:value, fn -> field.value end)
    |> input()
  end

  def input(%{type: "hidden"} = assigns) do
    ~H"""
    <input type="hidden" id={@id} name={@name} value={@value} {@rest} />
    """
  end

  def input(assigns) do
    id = assigns.id || assigns.name
    assigns = assign(assigns, id: id, help_id: "#{id}-help", error_id: "#{id}-error")

    assigns =
      assign(assigns,
        invalid: assigns.errors != [],
        described_by:
          [assigns.help && assigns.help_id, assigns.errors != [] && assigns.error_id]
          |> Enum.filter(& &1)
          |> Enum.join(" ")
          |> then(&if(&1 == "", do: nil, else: &1))
      )

    ~H"""
    <div class={[
      "hm-field",
      @layout == :row &&
        "grid grid-cols-1 gap-x-6 gap-y-1 py-2 sm:grid-cols-[12rem_1fr] sm:items-start",
      @layout == :stack && "flex flex-col gap-1"
    ]}>
      <.field_label :if={@type not in ~w(checkbox switch) and @label} {assigns} />
      <div class={[
        "flex flex-col gap-1 min-w-0",
        @layout == :row && @label == nil && "sm:col-start-2"
      ]}>
        <.control {assigns} />
        <p :if={@help} id={@help_id} class="text-caption text-fg-muted">{@help}</p>
        <div :if={@errors != []} id={@error_id} class="flex flex-col gap-0.5">
          <p :for={msg <- @errors} class="flex items-center gap-1 text-caption text-danger-fg">
            <.icon name="lucide-circle-alert" class="size-3.5" />{msg}
          </p>
        </div>
      </div>
    </div>
    """
  end

  defp field_label(assigns) do
    ~H"""
    <label
      :if={@type != "radio"}
      for={@id}
      class={["text-label font-medium text-fg", @layout == :row && "sm:pt-1.5"]}
    >
      {@label}
    </label>
    <span :if={@type == "radio"} id={"#{@id}-legend"} class="text-label font-medium text-fg">
      {@label}
    </span>
    """
  end

  defp control(%{type: type} = assigns) when type in ~w(checkbox switch) do
    assigns =
      assign_new(assigns, :checked, fn ->
        Form.normalize_value("checkbox", assigns[:value])
      end)

    ~H"""
    <label class="inline-flex items-center gap-2 cursor-pointer text-body text-fg min-h-8">
      <input type="hidden" name={@name} value="false" disabled={@rest[:disabled]} form={@rest[:form]} />
      <input
        type="checkbox"
        id={@id}
        name={@name}
        value="true"
        checked={@checked}
        role={@type == "switch" && "switch"}
        aria-invalid={@invalid && "true"}
        aria-describedby={@described_by}
        class={[
          if(@type == "switch", do: "toggle toggle-sm", else: "checkbox checkbox-sm"),
          "border-border-strong checked:border-brand checked:bg-brand checked:text-on-brand",
          @invalid && "border-danger",
          @class
        ]}
        {@rest}
      />
      <span :if={@label}>{@label}</span>
    </label>
    """
  end

  defp control(%{type: "radio"} = assigns) do
    ~H"""
    <div
      id={@id}
      role="radiogroup"
      aria-labelledby={@label && "#{@id}-legend"}
      aria-invalid={@invalid && "true"}
      aria-describedby={@described_by}
      class="flex flex-col gap-1.5"
    >
      <label
        :for={{label, value} <- normalize_options(@options)}
        class="inline-flex items-center gap-2 cursor-pointer text-body text-fg"
      >
        <input
          type="radio"
          name={@name}
          value={value}
          checked={to_string(value) == to_string(@value)}
          class={["radio radio-sm border-border-strong checked:text-brand", @class]}
          {@rest}
        />
        {label}
      </label>
    </div>
    """
  end

  defp control(%{type: "select"} = assigns) do
    ~H"""
    <select
      id={@id}
      name={@name}
      multiple={@multiple}
      aria-invalid={@invalid && "true"}
      aria-describedby={@described_by}
      class={[field_class(@invalid), "select h-8", @class]}
      {@rest}
    >
      <option :if={@prompt} value="">{@prompt}</option>
      {Phoenix.HTML.Form.options_for_select(@options, @value)}
    </select>
    """
  end

  defp control(%{type: "textarea"} = assigns) do
    ~H"""
    <textarea
      id={@id}
      name={@name}
      aria-invalid={@invalid && "true"}
      aria-describedby={@described_by}
      class={[field_class(@invalid), "textarea min-h-20 py-1.5 leading-5", @class]}
      {@rest}
    >{Phoenix.HTML.Form.normalize_value("textarea", @value)}</textarea>
    """
  end

  defp control(assigns) do
    ~H"""
    <input
      type={@type}
      name={@name}
      id={@id}
      value={Phoenix.HTML.Form.normalize_value(@type, @value)}
      aria-invalid={@invalid && "true"}
      aria-describedby={@described_by}
      class={[field_class(@invalid), "input h-8", @class]}
      {@rest}
    />
    """
  end

  defp field_class(invalid?) do
    [
      "w-full rounded-field bg-surface text-body text-fg shadow-none",
      "border-border-strong focus:border-brand focus-within:border-brand",
      invalid? && "border-danger focus:border-danger"
    ]
  end

  defp normalize_options(options) do
    Enum.map(options, fn
      {label, value} -> {label, value}
      value -> {value, value}
    end)
  end

  ## Headers

  @doc """
  A section header with optional subtitle and actions (used inside page bodies and
  by authentication pages). Page-level headers use `HelmsmanWeb.Components.Layout.page_header/1`.
  """
  slot :inner_block, required: true
  slot :subtitle
  slot :actions

  def header(assigns) do
    ~H"""
    <header class={[@actions != [] && "flex items-center justify-between gap-6", "pb-4"]}>
      <div>
        <h1 class="text-heading font-semibold text-fg">{render_slot(@inner_block)}</h1>
        <p :if={@subtitle != []} class="mt-1 text-body text-fg-muted">{render_slot(@subtitle)}</p>
      </div>
      <div :if={@actions != []} class="flex-none">{render_slot(@actions)}</div>
    </header>
    """
  end

  ## Flash

  @doc """
  Renders a flash notice. Info notices are a `role="status"` live region and fade out
  after 5 seconds (the delay is kept under reduced motion, only the fade is dropped);
  when the fade ends `app.js` clears the flash on the server, so the same message can
  appear again. Errors are `role="alert"` and stay until closed.
  """
  attr :id, :string, doc: "the optional id of flash container"
  attr :flash, :map, default: %{}, doc: "the map of flash messages to display"
  attr :title, :string, default: nil
  attr :kind, :atom, values: [:info, :error], doc: "used for styling and flash lookup"
  attr :rest, :global, doc: "the arbitrary HTML attributes to add to the flash container"
  slot :inner_block, doc: "the optional inner block that renders the flash message"

  def flash(assigns) do
    assigns = assign_new(assigns, :id, fn -> "flash-#{assigns.kind}" end)

    ~H"""
    <div
      :if={msg = render_slot(@inner_block) || Phoenix.Flash.get(@flash, @kind)}
      id={@id}
      role={if @kind == :error, do: "alert", else: "status"}
      data-hm-flash-clear={@kind == :info && JS.push("lv:clear-flash", value: %{key: @kind})}
      class={[
        "pointer-events-auto flex w-80 items-start gap-2 rounded-box border bg-raised px-3 py-2.5",
        "shadow-popover text-body text-fg",
        @kind == :info && "border-border animate-flash-out",
        @kind == :error && "border-danger"
      ]}
      {@rest}
    >
      <.icon :if={@kind == :info} name="lucide-circle-check" class="mt-0.5 size-4 text-success" />
      <.icon :if={@kind == :error} name="lucide-circle-alert" class="mt-0.5 size-4 text-danger" />
      <div class="min-w-0 flex-1">
        <p :if={@title} class="font-medium">{@title}</p>
        <p class="break-words">{msg}</p>
      </div>
      <button
        :if={@kind == :error}
        type="button"
        class="-mr-1 inline-flex size-6 items-center justify-center rounded-field text-fg-muted hover:bg-hover hover:text-fg"
        aria-label={dgettext("ui", "关闭")}
        phx-click={JS.push("lv:clear-flash", value: %{key: @kind}) |> hide("##{@id}")}
      >
        <.icon name="lucide-x" class="size-4" />
      </button>
    </div>
    """
  end

  ## JS Commands

  @doc "Shows an element with a short fade (no-op animation under reduced motion)."
  def show(js \\ %JS{}, selector) do
    JS.show(js,
      to: selector,
      time: 150,
      transition: {"transition-opacity ease-out duration-150", "opacity-0", "opacity-100"}
    )
  end

  @doc "Hides an element with a short fade."
  def hide(js \\ %JS{}, selector) do
    JS.hide(js,
      to: selector,
      time: 120,
      transition: {"transition-opacity ease-in duration-120", "opacity-100", "opacity-0"}
    )
  end

  @doc """
  Translates an error message using gettext.
  """
  def translate_error({msg, opts}) do
    if count = opts[:count] do
      Gettext.dngettext(HelmsmanWeb.Gettext, "errors", msg, msg, count, opts)
    else
      Gettext.dgettext(HelmsmanWeb.Gettext, "errors", msg, opts)
    end
  end

  @doc """
  Translates the errors for a field from a keyword list of errors.
  """
  def translate_errors(errors, field) when is_list(errors) do
    for {^field, {msg, opts}} <- errors, do: translate_error({msg, opts})
  end
end
