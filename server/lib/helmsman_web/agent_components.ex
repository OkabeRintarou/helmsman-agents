defmodule HelmsmanWeb.AgentComponents do
  @moduledoc """
  Agent pieces (add-agents-runs-ui D2, D3): the status of an agent view, the CLI
  (provider) label with a neutral terminal icon (no third-party marks, web-visual-system
  「图标集与第三方商标」), the runtime status and the "who can trigger" text.
  """
  use Phoenix.Component
  use Gettext, backend: HelmsmanWeb.Gettext

  import HelmsmanWeb.CoreComponents, only: [icon: 1]
  import HelmsmanWeb.Components.Actor, only: [presence_dot: 1]
  import HelmsmanWeb.Components.Status, only: [badge: 1]

  @providers ~w(claude codex copilot cursor)

  @doc "The CLIs a managed agent can use."
  def providers, do: @providers

  @doc "Display name of a CLI."
  def provider_label("claude"), do: "Claude Code"
  def provider_label("codex"), do: "Codex"
  def provider_label("copilot"), do: "Copilot CLI"
  def provider_label("cursor"), do: "Cursor CLI"
  def provider_label(nil), do: ""
  def provider_label(other), do: to_string(other)

  @doc """
  The status of an agent view (spec web-agents Agent 列表页), the first that holds:
  `:archived`, `:disabled`, `{:busy, n}`, `:idle`, `:offline` (managed) or `:online` /
  `nil` (external, from the names in `online`).
  """
  def status(view, online \\ MapSet.new())
  def status(%{archived: true}, _online), do: :archived
  def status(%{disabled: true}, _online), do: :disabled

  def status(%{kind: "managed"} = view, _online) do
    cond do
      (view[:active_runs] || 0) > 0 -> {:busy, view.active_runs}
      runtime_online?(view.runtime) -> :idle
      true -> :offline
    end
  end

  def status(%{name: name}, online), do: if(MapSet.member?(online, name), do: :online)

  defp runtime_online?(%{status: "online", disabled: false}), do: true
  defp runtime_online?(_runtime), do: false

  @doc "Label of `status/2`."
  def status_label(:archived), do: dgettext("ui", "已归档")
  def status_label(:disabled), do: dgettext("ui", "已停用")
  def status_label({:busy, n}), do: dgettext("ui", "忙碌（%{n}）", n: n)
  def status_label(:idle), do: dgettext("ui", "空闲")
  def status_label(:offline), do: dgettext("ui", "离线")
  def status_label(:online), do: dgettext("ui", "在线")
  def status_label(nil), do: ""

  @doc "The presence dot of `status/2`."
  def presence(:idle), do: :online
  def presence(:online), do: :online
  def presence({:busy, _}), do: :busy
  def presence(:offline), do: :offline
  def presence(_), do: nil

  @doc "Status badge of an agent (dot + label); renders nothing for `nil`."
  attr :id, :string, default: nil
  attr :status, :any, required: true
  attr :class, :any, default: nil

  def agent_status(%{status: nil} = assigns), do: ~H""

  def agent_status(assigns) do
    ~H"""
    <span
      id={@id}
      data-agent-status={status_key(@status)}
      class={["inline-flex items-center gap-1.5 text-body", tone_class(@status), @class]}
    >
      <.presence_dot :if={presence(@status)} status={presence(@status)} />
      <.icon :if={@status == :disabled} name="lucide-circle-pause" class="size-3.5" />
      <.icon :if={@status == :archived} name="lucide-archive" class="size-3.5" />
      {status_label(@status)}
    </span>
    """
  end

  defp status_key({:busy, _}), do: "busy"
  defp status_key(status), do: to_string(status)

  defp tone_class({:busy, _}), do: "text-brand-fg"
  defp tone_class(status) when status in [:idle, :online], do: "text-success-fg"
  defp tone_class(_), do: "text-fg-muted"

  @doc "CLI icon and name."
  attr :provider, :string, required: true
  attr :class, :any, default: nil

  def provider(assigns) do
    ~H"""
    <span class={["inline-flex items-center gap-1.5", @class]} data-provider={@provider}>
      <.icon name="lucide-square-terminal" class="size-4 text-fg-muted" />
      <span class="truncate">{provider_label(@provider)}</span>
    </span>
    """
  end

  @doc "Status of a runtime view: `:disabled`, `:unavailable`, `:online` or `:offline`."
  def runtime_status(%{disabled: true}), do: :disabled
  def runtime_status(%{unavailable_reason: reason}) when is_binary(reason), do: :unavailable
  def runtime_status(%{status: "online"}), do: :online
  def runtime_status(_runtime), do: :offline

  @doc "Badge of `runtime_status/1`, with the reason of an unavailable runtime."
  attr :runtime, :map, required: true
  attr :id, :string, default: nil

  def runtime_badge(assigns) do
    assigns = assign(assigns, :status, runtime_status(assigns.runtime))

    ~H"""
    <span id={@id} data-runtime-status={@status} class="inline-flex min-w-0 items-center gap-1.5">
      <%= case @status do %>
        <% :online -> %>
          <.presence_dot status={:online} />
          <span class="text-success-fg">{dgettext("ui", "在线")}</span>
        <% :offline -> %>
          <.presence_dot status={:offline} />
          <span class="text-fg-muted">{dgettext("ui", "离线")}</span>
        <% :disabled -> %>
          <.badge>{dgettext("ui", "已禁用")}</.badge>
        <% :unavailable -> %>
          <.badge tone={:warning}>{dgettext("ui", "不可用")}</.badge>
          <span class="truncate text-caption text-fg-muted" data-unavailable-reason>
            {@runtime.unavailable_reason}
          </span>
      <% end %>
    </span>
    """
  end

  @doc "Who can trigger the agent (`access`), with member names for `members`."
  def access_label(%{access: "workspace"}, _names), do: dgettext("ui", "工作区成员")

  def access_label(%{access: "members"}, names),
    do: dgettext("ui", "指定成员：%{names}", names: Enum.join(names, "、"))

  def access_label(_view, _names), do: dgettext("ui", "仅所属用户")

  @doc """
  Daily runs of the 用量 tab (spec web-agents Agent 详情页, design D4): one stacked bar a
  day, succeeded / failed / cancelled from the bottom (`days` of
  `Helmsman.Runs.usage_for_agent/3`). Every non-empty day has a `<title>` with the three
  counts; an empty period draws only the baseline.
  """
  attr :days, :list, required: true
  attr :id, :string, required: true

  def usage_bars(assigns) do
    {bar, gap, height} = {8, 2, 48}
    max = assigns.days |> Enum.map(&day_total/1) |> Enum.max(fn -> 0 end)
    width = max(length(assigns.days) * (bar + gap) - gap, 1)

    bars =
      for {day, i} <- Enum.with_index(assigns.days), day_total(day) > 0 do
        %{
          id: "#{assigns.id}-#{day.date}",
          x: i * (bar + gap),
          title:
            dgettext("ui", "%{date}：成功 %{ok}，失败 %{failed}，已停止 %{cancelled}",
              date: Date.to_iso8601(day.date),
              ok: day.succeeded,
              failed: day.failed,
              cancelled: day.cancelled
            ),
          parts:
            stack(
              [
                {day.succeeded, "fill-success"},
                {day.failed, "fill-danger"},
                {day.cancelled, "fill-fg-subtle"}
              ],
              max,
              height - 1
            )
        }
      end

    assigns = assign(assigns, width: width, height: height, bar: bar, bars: bars)

    ~H"""
    <svg
      id={@id}
      viewBox={"0 0 #{@width} #{@height}"}
      width={@width}
      height={@height}
      role="img"
      aria-label={dgettext("ui", "近 %{n} 天每天的运行数", n: length(@days))}
      class="max-w-full"
    >
      <line
        x1="0"
        x2={@width}
        y1={@height - 0.5}
        y2={@height - 0.5}
        class="stroke-border-strong"
        stroke-width="1"
      />
      <g :for={b <- @bars} id={b.id} data-usage-day>
        <title>{b.title}</title>
        <rect
          :for={p <- b.parts}
          x={b.x}
          y={p.y}
          width={@bar}
          height={p.h}
          class={p.class}
        />
      </g>
    </svg>
    """
  end

  defp day_total(day), do: day.succeeded + day.failed + day.cancelled

  # Segments from the baseline up; each non-zero count gets at least one pixel.
  defp stack(counts, max, room) do
    {parts, _top} =
      Enum.reduce(counts, {[], room}, fn
        {0, _class}, acc ->
          acc

        {n, class}, {parts, top} ->
          h = max(round(n / max * room), 1)
          {[%{y: top - h, h: h, class: class} | parts], top - h}
      end)

    Enum.reverse(parts)
  end

  @doc "An integer with thousands separators: 1,234,567."
  def thousands(nil), do: "0"

  def thousands(n) when is_integer(n) do
    n
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end
end
