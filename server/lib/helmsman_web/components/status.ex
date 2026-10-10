defmodule HelmsmanWeb.Components.Status do
  @moduledoc """
  Single source of the task / run status visuals (spec web-visual-system):
  icon, semantic color and label. Unknown values render a neutral "未知" badge.
  """
  use Phoenix.Component
  use Gettext, backend: HelmsmanWeb.Gettext

  import HelmsmanWeb.CoreComponents, only: [icon: 1, tooltip: 1]

  # tone => {graphic color class, text color class, badge background class}
  @tones %{
    muted: {"text-fg-muted", "text-fg-muted", "bg-hover"},
    subtle: {"text-fg-subtle", "text-fg-subtle", "bg-hover"},
    brand: {"text-brand", "text-brand-fg", "tint-brand"},
    success: {"text-success", "text-success-fg", "tint-success"},
    warning: {"text-warning", "text-warning-fg", "tint-warning"},
    danger: {"text-danger", "text-danger-fg", "tint-danger"},
    info: {"text-info", "text-info-fg", "tint-info"},
    review: {"text-review", "text-review-fg", "tint-review"}
  }

  @task_statuses ~w(new in_progress done verified rejected cancelled)
  @run_statuses ~w(deferred queued claimed running cancelling succeeded failed cancelled)

  @doc "Known task statuses (lower-case strings)."
  def task_statuses, do: @task_statuses

  @doc "Known run statuses."
  def run_statuses, do: @run_statuses

  @doc """
  Visual spec of a task status: `%{key, label, icon, tone, filled?, animation}`.
  Accepts atoms or strings in any case (`:in_progress`, `"IN_PROGRESS"`).
  """
  def task_status(status), do: Map.get(task_specs(), normalize(status)) || unknown()

  @doc "Visual spec of a run status (see `task_status/1`)."
  def run_status(status), do: Map.get(run_specs(), normalize(status)) || unknown()

  defp task_specs do
    %{
      "new" => spec("new", dgettext("ui", "新建"), "lucide-circle-dashed", :muted),
      "in_progress" => spec("in_progress", dgettext("ui", "进行中"), "lucide-circle-dot", :warning),
      "done" => spec("done", dgettext("ui", "待验收"), "lucide-circle-check", :info),
      "verified" => %{
        spec("verified", dgettext("ui", "已验收"), "lucide-check", :success)
        | filled?: true
      },
      "rejected" => spec("rejected", dgettext("ui", "已拒绝"), "lucide-circle-x", :danger),
      "cancelled" => spec("cancelled", dgettext("ui", "已撤销"), "lucide-circle-slash", :subtle)
    }
  end

  defp run_specs do
    %{
      "deferred" => spec("deferred", dgettext("ui", "等待中"), "lucide-clock", :muted),
      "queued" => spec("queued", dgettext("ui", "排队中"), "lucide-ellipsis", :muted),
      "claimed" => %{
        spec("claimed", dgettext("ui", "准备中"), "lucide-loader-circle", :info)
        | animation: :spin
      },
      "running" => %{
        spec("running", dgettext("ui", "运行中"), "lucide-loader-circle", :brand)
        | animation: :spin_pulse
      },
      "cancelling" => spec("cancelling", dgettext("ui", "停止中"), "lucide-square", :warning),
      "succeeded" => spec("succeeded", dgettext("ui", "已结束"), "lucide-check", :success),
      "failed" => spec("failed", dgettext("ui", "失败"), "lucide-x", :danger),
      "cancelled" => spec("cancelled", dgettext("ui", "已停止"), "lucide-slash", :subtle)
    }
  end

  defp spec(key, label, icon, tone),
    do: %{key: key, label: label, icon: icon, tone: tone, filled?: false, animation: nil}

  defp unknown, do: spec("unknown", dgettext("ui", "未知"), "lucide-circle-question-mark", :muted)

  defp normalize(nil), do: nil
  defp normalize(status) when is_atom(status), do: status |> Atom.to_string() |> String.downcase()
  defp normalize(status) when is_binary(status), do: String.downcase(status)
  defp normalize(_), do: nil

  @doc false
  def tone_classes(tone), do: Map.fetch!(@tones, tone)

  @doc """
  Task status badge: tinted background, status icon and label.

      <.status_badge status={@task.status} />
  """
  attr :status, :any, required: true
  attr :class, :any, default: nil

  def status_badge(assigns) do
    assigns = assign(assigns, :spec, task_status(assigns.status))

    ~H"""
    <.badge tone={@spec.tone} class={@class} data-status={@spec.key}>
      <.glyph spec={@spec} />
      {@spec.label}
    </.badge>
    """
  end

  @doc """
  Task status icon only, with an accessible name and tooltip "状态：<label>".
  """
  attr :id, :string, default: nil
  attr :status, :any, required: true
  attr :class, :any, default: nil

  def status_icon(assigns) do
    spec = task_status(assigns.status)
    label = dgettext("ui", "状态：%{label}", label: spec.label)

    assigns = assign(assigns, spec: spec, label: label)

    ~H"""
    <.tooltip text={@label} class={@class}>
      <span id={@id} role="img" aria-label={@label} data-status={@spec.key} class="inline-flex">
        <.glyph spec={@spec} />
      </span>
    </.tooltip>
    """
  end

  @doc "Run status badge (running spins and pulses only when motion is allowed)."
  attr :status, :any, required: true
  attr :class, :any, default: nil

  def run_status_badge(assigns) do
    assigns = assign(assigns, :spec, run_status(assigns.status))

    ~H"""
    <.badge
      tone={@spec.tone}
      class={[@spec.animation == :spin_pulse && "motion-safe:animate-pulse-soft", @class]}
      data-run-status={@spec.key}
    >
      <.glyph spec={@spec} />
      {@spec.label}
    </.badge>
    """
  end

  attr :spec, :map, required: true

  defp glyph(%{spec: %{filled?: true}} = assigns) do
    {graphic, _, _} = tone_classes(assigns.spec.tone)
    assigns = assign(assigns, :graphic, graphic)

    ~H"""
    <span class={[
      "inline-flex size-3.5 items-center justify-center rounded-full bg-current",
      @graphic
    ]}>
      <.icon name={@spec.icon} class="size-2.5 text-surface" />
    </span>
    """
  end

  defp glyph(assigns) do
    {graphic, _, _} = tone_classes(assigns.spec.tone)
    assigns = assign(assigns, :graphic, graphic)

    ~H"""
    <.icon
      name={@spec.icon}
      class={["size-3.5", @graphic, @spec.animation && "motion-safe:animate-spin"]}
    />
    """
  end

  @doc """
  Small rounded label. Tones: `muted`, `subtle`, `brand`, `success`, `warning`,
  `danger`, `info`, `review`. Text uses the tone's text color on a tint of its
  graphic color mixed into surface (12% light / 16% dark).
  """
  attr :tone, :atom, default: :muted, values: Map.keys(@tones)
  attr :class, :any, default: nil
  attr :rest, :global
  slot :inner_block, required: true

  def badge(assigns) do
    {_, text, tint} = tone_classes(assigns.tone)
    assigns = assign(assigns, text: text, tint: tint)

    ~H"""
    <span
      class={[
        "inline-flex h-5 items-center gap-1 whitespace-nowrap rounded-badge px-1.5",
        "text-caption font-medium",
        @text,
        @tint,
        @class
      ]}
      {@rest}
    >
      {render_slot(@inner_block)}
    </span>
    """
  end

  @doc """
  Priority as three signal bars: low 1, medium 2, high 3 (warning color).
  """
  attr :priority, :any, required: true
  attr :class, :any, default: nil

  def priority_icon(assigns) do
    {level, label} =
      case normalize(assigns.priority) do
        "high" -> {3, dgettext("ui", "高")}
        "medium" -> {2, dgettext("ui", "中")}
        "low" -> {1, dgettext("ui", "低")}
        _ -> {0, dgettext("ui", "未知")}
      end

    assigns =
      assign(assigns,
        level: level,
        label: dgettext("ui", "优先级：%{label}", label: label)
      )

    ~H"""
    <svg
      viewBox="0 0 14 14"
      role="img"
      aria-label={@label}
      data-priority={@level}
      class={["size-3.5", if(@level == 3, do: "text-warning", else: "text-fg-muted"), @class]}
    >
      <title>{@label}</title>
      <rect
        :for={bar <- 1..3}
        x={1 + (bar - 1) * 4.5}
        y={12 - bar * 3.5}
        width="3"
        height={bar * 3.5}
        rx="0.75"
        class={if(bar <= @level, do: "fill-current", else: "fill-border-strong")}
      />
    </svg>
    """
  end
end
