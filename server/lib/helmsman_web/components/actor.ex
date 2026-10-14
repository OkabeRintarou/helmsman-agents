defmodule HelmsmanWeb.Components.Actor do
  @moduledoc """
  Identity components: `actor_mark/1`, `actor_chip/1`, `presence_dot/1`, `working_chip/1`.

  An actor is a map `%{name, kind, owner_name, managed?, state}` where `kind` is
  `:human | :agent | :squad | :system` and `state` is `:active | :disabled | :archived`;
  `provider` (an Agent's CLI) and `avatar_url` come from the workspace's appearance
  table (`HelmsmanWeb.Appearance.decorate/2`).
  """
  use Phoenix.Component
  use Gettext, backend: HelmsmanWeb.Gettext

  import HelmsmanWeb.CoreComponents, only: [icon: 1, tooltip_class: 1]

  alias HelmsmanWeb.Brands
  alias HelmsmanWeb.Components.Brand

  @doc """
  The graphic part of an identity (add-actor-avatars D2), from the `actor` map
  (`kind`, `name`, and when known `provider`, `managed?`, `avatar_url`, `state`):

  * humans: a circle, the avatar or the initial on one of eight tints chosen by name;
  * managed Agents: a rounded square, the avatar or the CLI's brand icon on the plate;
    external Agents and unknown CLIs: the neutral square with Lucide `bot`;
  * squads: the avatar or Lucide `users` on the brand fill; the system: an outlined
    square with Lucide `settings` (never an avatar).

  Disabled / archived identities are desaturated. The avatar `<img data-avatar>` sits on
  top of the default mark; `app.js` hides it when it fails to load. Decorative unless
  `label` is given.
  """
  attr :actor, :map, required: true
  attr :size, :atom, default: :sm, values: [:xs, :sm, :md, :lg, :xl]
  attr :label, :string, default: nil
  attr :class, :any, default: nil

  def actor_mark(assigns) do
    actor = assigns.actor
    kind = actor |> Map.get(:kind, :human) |> to_kind()
    cli = if kind == :agent and Map.get(actor, :managed?) != false, do: cli_icon(actor)
    src = if kind != :system, do: Map.get(actor, :avatar_url)

    assigns =
      assign(assigns,
        kind: kind,
        cli: cli,
        src: src,
        inactive?: Map.get(actor, :state) in [:disabled, :archived, "disabled", "archived"],
        name: Map.get(actor, :name) || ""
      )

    ~H"""
    <span
      class={[
        "relative inline-flex shrink-0 overflow-hidden",
        Brand.size_class(@size),
        if(@kind == :human, do: "rounded-full", else: "rounded-[25%]"),
        @inactive? && "opacity-70 grayscale",
        @class
      ]}
      data-actor-mark={@kind}
      role={@label && "img"}
      aria-label={@label}
      aria-hidden={if(@label, do: nil, else: "true")}
    >
      <span
        :if={@kind == :human}
        class={["inline-flex size-full items-center justify-center", tint(@name)]}
        data-tint={tint_index(@name)}
      >
        <svg viewBox="0 0 100 100" class="size-full" aria-hidden="true">
          <text
            x="50"
            y="50"
            text-anchor="middle"
            dominant-baseline="central"
            font-size="45"
            font-weight="500"
            fill="currentColor"
            phx-no-format
          >{initial(@name)}</text>
        </svg>
      </span>
      <Brand.brand_icon
        :if={@kind == :agent}
        icon={@cli}
        fallback={:bot}
        size={@size}
      />
      <span
        :if={@kind == :squad}
        class="inline-flex size-full items-center justify-center bg-id-squad text-id-squad-ink"
      >
        <.icon name="lucide-users" class="size-[60%]" />
      </span>
      <span
        :if={@kind == :system}
        class="inline-flex size-full items-center justify-center rounded-[25%] border border-border-strong bg-surface text-fg-muted"
      >
        <.icon name="lucide-settings" class="size-[60%]" />
      </span>
      <img
        :if={@src}
        data-avatar
        src={@src}
        alt=""
        class="absolute inset-0 size-full object-cover"
        draggable="false"
      />
    </span>
    """
  end

  defp cli_icon(actor) do
    icon = Brands.cli_icon(Map.get(actor, :provider))
    if icon && Brand.vendored?(icon), do: icon
  end

  @tints {"bg-id-tint-1 text-id-tint-1-ink", "bg-id-tint-2 text-id-tint-2-ink",
          "bg-id-tint-3 text-id-tint-3-ink", "bg-id-tint-4 text-id-tint-4-ink",
          "bg-id-tint-5 text-id-tint-5-ink", "bg-id-tint-6 text-id-tint-6-ink",
          "bg-id-tint-7 text-id-tint-7-ink", "bg-id-tint-8 text-id-tint-8-ink"}

  @doc "The initial's tint (1..8) of a human named `name`: the same name always gets the same tint."
  def tint_index(name), do: :erlang.phash2(name, 8) + 1

  defp tint(name), do: elem(@tints, tint_index(name) - 1)

  defp initial(name),
    do: name |> String.trim() |> String.first() |> Kernel.||("?") |> String.upcase()

  @doc """
  Identity mark (`actor_mark/1`, `size` passed through) plus name for a human, Agent,
  squad or the system.

  * Agents get a tooltip with the owner and "托管" / "外接" (only when the map has
    `managed?`; a bare `%{name, kind}` reference claims neither), and for managed
    Agents with a known CLI its display name (「所属：alice · 托管 · Claude Code」).
  * `compact` shows only the icon; the name moves to the tooltip and accessible name.
  * `disabled_reason` renders the chip at 60% opacity and exposes the reason
    (tooltip, and as visually hidden text for assistive technology).
  * Disabled / archived actors get a "（已停用）" / "（已归档）" suffix.
  * Unclaimed humans (`unclaimed: true`, created by an import) get a "（未认领）"
    suffix and a tooltip saying so (add-data-settings-ui D11).
  """
  attr :id, :string, default: nil
  attr :actor, :map, required: true
  attr :compact, :boolean, default: false
  attr :size, :atom, default: :sm, values: [:xs, :sm, :md, :lg, :xl]
  attr :presence, :atom, default: nil, values: [nil, :online, :busy, :offline]
  attr :disabled_reason, :string, default: nil
  attr :class, :any, default: nil

  def actor_chip(assigns) do
    actor = assigns.actor
    kind = actor |> Map.get(:kind, :human) |> to_kind()
    unclaimed? = kind == :human and unclaimed?(actor)

    name =
      Map.get(actor, :name, "") <>
        if(unclaimed?, do: dgettext("ui", "（未认领）"), else: state_suffix(Map.get(actor, :state)))

    info =
      if unclaimed?,
        do: dgettext("ui", "导入的身份，尚未被成员认领"),
        else: agent_info(kind, actor)

    parts = [assigns.compact && name, info, assigns.disabled_reason]
    tip = parts |> Enum.filter(&is_binary/1) |> Enum.join(" · ")

    assigns =
      assign(assigns,
        kind: kind,
        name: name,
        tip: if(tip == "", do: nil, else: tip),
        info: info
      )

    ~H"""
    <span
      id={@id}
      class={[
        "relative inline-flex max-w-full items-center gap-1.5 align-middle text-body",
        @tip && "hm-tooltip-host",
        @disabled_reason && "opacity-60",
        @kind == :system && "text-fg-muted",
        @kind != :system && "text-fg",
        @class
      ]}
      data-actor-kind={@kind}
      tabindex={@tip && "0"}
    >
      <span class="relative inline-flex">
        <.actor_mark actor={Map.put(@actor, :kind, @kind)} size={@size} />
        <.presence_dot
          :if={@presence}
          status={@presence}
          class="absolute -right-0.5 -bottom-0.5 ring-2 ring-surface"
        />
      </span>
      <span class={["truncate", @compact && "sr-only"]}>{@name}</span>
      <span :if={@info} class="sr-only">{@info}</span>
      <span :if={@disabled_reason} class="sr-only">{@disabled_reason}</span>
      <span :if={@tip} aria-hidden="true" class={tooltip_class(:bottom)}>{@tip}</span>
    </span>
    """
  end

  defp to_kind(kind) when kind in [:human, :agent, :squad, :system], do: kind
  defp to_kind("agent"), do: :agent
  defp to_kind("squad"), do: :squad
  defp to_kind("system"), do: :system
  defp to_kind(_), do: :human

  defp state_suffix(state) when state in [:disabled, "disabled"], do: dgettext("ui", "（已停用）")
  defp state_suffix(state) when state in [:archived, "archived"], do: dgettext("ui", "（已归档）")
  defp state_suffix(_), do: ""

  defp unclaimed?(actor),
    do: Map.get(actor, :unclaimed) == true or Map.get(actor, :state) in [:unclaimed, "unclaimed"]

  defp agent_info(:agent, actor) do
    mode =
      case Map.fetch(actor, :managed?) do
        {:ok, true} -> dgettext("ui", "托管")
        {:ok, _} -> dgettext("ui", "外接")
        :error -> nil
      end

    cli = if Map.get(actor, :managed?) == true, do: Brands.cli_name(Map.get(actor, :provider))
    owner = Map.get(actor, :owner_name)
    owner = owner && dgettext("ui", "所属：%{owner}", owner: owner)

    case Enum.filter([owner, mode, cli], & &1) do
      [] -> nil
      parts -> Enum.join(parts, " · ")
    end
  end

  defp agent_info(_kind, _actor), do: nil

  @doc """
  Presence dot: online (success), busy (brand), offline (hollow fg-subtle);
  unknown renders nothing.
  """
  attr :status, :atom, default: nil, values: [nil, :online, :busy, :offline]
  attr :class, :any, default: nil

  def presence_dot(%{status: nil} = assigns), do: ~H""

  def presence_dot(assigns) do
    label =
      case assigns.status do
        :online -> dgettext("ui", "在线")
        :busy -> dgettext("ui", "忙碌")
        :offline -> dgettext("ui", "离线")
      end

    assigns = assign(assigns, :label, label)

    ~H"""
    <span
      role="img"
      aria-label={@label}
      data-presence={@status}
      class={[
        "inline-block size-2 shrink-0 rounded-full",
        @status == :online && "bg-success",
        @status == :busy && "bg-brand",
        @status == :offline && "border border-fg-subtle bg-transparent",
        @class
      ]}
    />
    """
  end

  @doc """
  "<Agent> 正在处理" marker with an activity indicator. With several Agents it shows the
  first name plus "等 N 个"; the tooltip lists all names. `on_click` runs on click
  (e.g. open the run log).
  """
  attr :id, :string, required: true
  attr :agents, :list, required: true, doc: "Agent names"
  attr :on_click, :any, default: nil, doc: "event name or %Phoenix.LiveView.JS{}"
  attr :class, :any, default: nil

  def working_chip(%{agents: []} = assigns), do: ~H""

  def working_chip(assigns) do
    [first | _] = assigns.agents
    count = length(assigns.agents)

    text =
      if count == 1,
        do: dgettext("ui", "%{name} 正在处理", name: first),
        else: dgettext("ui", "%{name} 等 %{count} 个正在处理", name: first, count: count)

    assigns = assign(assigns, text: text, all: Enum.join(assigns.agents, "、"))

    ~H"""
    <span class={["hm-tooltip-host relative inline-flex", @class]}>
      <button
        id={@id}
        type="button"
        phx-click={@on_click}
        aria-describedby={"#{@id}-tip"}
        class="inline-flex h-6 items-center gap-1.5 rounded-badge px-2 text-caption font-medium tint-brand text-brand-fg hover:underline"
      >
        <span class="relative inline-flex size-2">
          <span class="absolute inline-flex size-full rounded-full bg-brand opacity-60 motion-safe:animate-ping" />
          <span class="relative inline-flex size-2 rounded-full bg-brand" />
        </span>
        {@text}
      </button>
      <span id={"#{@id}-tip"} role="tooltip" class={tooltip_class(:bottom)}>{@all}</span>
    </span>
    """
  end
end
