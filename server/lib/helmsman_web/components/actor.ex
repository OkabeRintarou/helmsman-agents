defmodule HelmsmanWeb.Components.Actor do
  @moduledoc """
  Identity components: `avatar/1`, `actor_chip/1`, `presence_dot/1`, `working_chip/1`.

  An actor is a map `%{name, kind, owner_name, managed?, state}` where `kind` is
  `:human | :agent | :squad | :system` and `state` is `:active | :disabled | :archived`.
  """
  use Phoenix.Component
  use Gettext, backend: HelmsmanWeb.Gettext

  import HelmsmanWeb.CoreComponents, only: [icon: 1, tooltip_class: 1]

  @doc "Round avatar: image when `src` is given, otherwise the initial on a neutral tint."
  attr :name, :string, required: true
  attr :src, :string, default: nil
  attr :size, :atom, default: :sm, values: [:xs, :sm, :md]
  attr :class, :any, default: nil

  def avatar(assigns) do
    ~H"""
    <span
      aria-hidden="true"
      class={[
        "inline-flex shrink-0 items-center justify-center overflow-hidden rounded-full",
        "bg-selected font-medium text-fg",
        avatar_size(@size),
        @class
      ]}
    >
      <img :if={@src} src={@src} alt="" class="size-full object-cover" />
      <span :if={!@src}>{initial(@name)}</span>
    </span>
    """
  end

  defp avatar_size(:xs), do: "size-4 text-micro"
  defp avatar_size(:sm), do: "size-5 text-micro"
  defp avatar_size(:md), do: "size-7 text-label"

  defp initial(name),
    do: name |> String.trim() |> String.first() |> Kernel.||("?") |> String.upcase()

  @doc """
  Icon or avatar plus name for a human, Agent, squad or the system.

  * Agents get a tooltip with the owner and "托管" / "外接" (only when the map has
    `managed?`; a bare `%{name, kind}` reference claims neither).
  * `compact` shows only the icon; the name moves to the tooltip and accessible name.
  * `disabled_reason` renders the chip at 60% opacity and exposes the reason
    (tooltip, and as visually hidden text for assistive technology).
  * Disabled / archived actors get a "（已停用）" / "（已归档）" suffix.
  """
  attr :id, :string, default: nil
  attr :actor, :map, required: true
  attr :compact, :boolean, default: false
  attr :presence, :atom, default: nil, values: [nil, :online, :busy, :offline]
  attr :disabled_reason, :string, default: nil
  attr :class, :any, default: nil

  def actor_chip(assigns) do
    actor = assigns.actor
    kind = actor |> Map.get(:kind, :human) |> to_kind()
    name = Map.get(actor, :name, "") <> state_suffix(Map.get(actor, :state))
    info = agent_info(kind, actor)
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
        <.avatar :if={@kind == :human} name={@name} src={@actor[:avatar_url]} />
        <.icon :if={@kind == :agent} name="lucide-bot" class="size-4 text-fg-muted" />
        <.icon :if={@kind == :squad} name="lucide-users" class="size-4 text-fg-muted" />
        <.icon :if={@kind == :system} name="lucide-settings" class="size-4 text-fg-muted" />
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

  defp agent_info(:agent, actor) do
    mode =
      case Map.fetch(actor, :managed?) do
        {:ok, true} -> dgettext("ui", "托管")
        {:ok, _} -> dgettext("ui", "外接")
        :error -> nil
      end

    case {Map.get(actor, :owner_name), mode} do
      {nil, mode} -> mode
      {owner, nil} -> dgettext("ui", "所属：%{owner}", owner: owner)
      {owner, mode} -> dgettext("ui", "所属：%{owner} · %{mode}", owner: owner, mode: mode)
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
