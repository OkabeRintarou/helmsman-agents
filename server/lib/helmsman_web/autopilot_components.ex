defmodule HelmsmanWeb.AutopilotComponents do
  @moduledoc """
  Shared pieces of the autopilot pages (add-squads-autopilots-ui D8, D11, D14): labels of
  modes, sources, record statuses and reason codes, disabled reasons and warnings, local
  times, and the enable switch.
  """
  use HelmsmanWeb, :html

  alias HelmsmanWeb.CronText

  @timezones ~w(UTC Asia/Shanghai Asia/Hong_Kong Asia/Taipei Asia/Tokyo Asia/Seoul
                Asia/Singapore Asia/Kolkata Asia/Dubai Australia/Sydney Pacific/Auckland
                Europe/London Europe/Dublin Europe/Paris Europe/Berlin Europe/Amsterdam
                Europe/Madrid Europe/Rome Europe/Stockholm Europe/Moscow Africa/Cairo
                Africa/Johannesburg America/New_York America/Chicago America/Denver
                America/Los_Angeles America/Anchorage America/Toronto America/Vancouver
                America/Mexico_City America/Sao_Paulo America/Argentina/Buenos_Aires
                Pacific/Honolulu)

  ## Time zones and times

  @doc "IANA names offered by the time zone input (any valid name may be typed)."
  def timezones, do: @timezones

  @doc "`tz` when it is a valid IANA name, otherwise UTC."
  def timezone(tz) when is_binary(tz) and byte_size(tz) in 1..64 do
    case DateTime.shift_zone(DateTime.utc_now(), tz) do
      {:ok, _} -> tz
      {:error, _} -> "UTC"
    end
  end

  def timezone(_tz), do: "UTC"

  @doc "The browser's time zone from the LiveView connect params (`UTC` when absent or invalid)."
  def browser_timezone(socket) do
    if Phoenix.LiveView.connected?(socket),
      do: timezone(Phoenix.LiveView.get_connect_params(socket)["timezone"]),
      else: "UTC"
  end

  @doc """
  `at` as `YYYY-MM-DD HH:MM` in `tz` (`weekday: true` adds 「周三」). Falls back to UTC
  with a 「UTC」 suffix when the zone cannot be resolved.
  """
  def local_time(at, tz, opts \\ [])
  def local_time(nil, _tz, _opts), do: nil

  def local_time(%DateTime{} = at, tz, opts) do
    {local, suffix} =
      case DateTime.shift_zone(at, if(tz in [nil, "UTC"], do: "Etc/UTC", else: tz)) do
        {:ok, local} -> {local, ""}
        {:error, _} -> {at, " UTC"}
      end

    day =
      if opts[:weekday],
        do: " " <> CronText.weekday_name(rem(Date.day_of_week(local), 7)),
        else: ""

    Calendar.strftime(local, "%Y-%m-%d") <> day <> Calendar.strftime(local, " %H:%M") <> suffix
  end

  @doc "「3 小时后」-style text for a future `at` (past times read 「即将」)."
  def future_text(%DateTime{} = at, now \\ DateTime.utc_now()) do
    secs = DateTime.diff(at, now, :second)

    cond do
      secs < 60 -> dgettext("ui", "即将")
      secs < 3600 -> dgettext("ui", "%{n} 分钟后", n: div(secs, 60))
      secs < 86_400 -> dgettext("ui", "%{n} 小时后", n: div(secs, 3600))
      true -> dgettext("ui", "%{n} 天后", n: div(secs, 86_400))
    end
  end

  ## Labels

  @doc "「建任务」/「仅运行」."
  def mode_label(mode) when mode in ["create_task", :create_task], do: dgettext("ui", "建任务")
  def mode_label(mode) when mode in ["run_only", :run_only], do: dgettext("ui", "仅运行")
  def mode_label(mode), do: to_string(mode)

  @doc "「跳过」/「排队」."
  def overlap_label(o) when o in ["queue", :queue], do: dgettext("ui", "排队")
  def overlap_label(_), do: dgettext("ui", "跳过")

  @doc "How the autopilot is triggered: the cron in words, or 「仅手动」."
  def trigger_text(%{cron: cron, timezone: tz}) when is_binary(cron) and cron != "",
    do: CronText.describe(cron, tz)

  def trigger_text(_autopilot), do: dgettext("ui", "仅手动")

  @doc "Source of a record: 「定时」, 「手动 · alice」 or 「webhook」."
  def source_label(%{source: source} = record), do: source_label(to_string(source), record)

  defp source_label("schedule", _record), do: dgettext("ui", "定时")

  defp source_label("manual", %{initiator: %{name: name}}) when is_binary(name),
    do: dgettext("ui", "手动 · %{name}", name: name)

  defp source_label("manual", _record), do: dgettext("ui", "手动")

  defp source_label("webhook", %{delivery_id: id}) when is_binary(id) and id != "",
    do: "webhook · " <> String.slice(id, 0, 8)

  defp source_label("webhook", _record), do: "webhook"
  defp source_label(other, _record), do: other

  @doc "Label and tone of a record status."
  def record_status(status) do
    case to_string(status) do
      "pending" -> {dgettext("ui", "排队中"), :muted, "lucide-ellipsis"}
      "skipped" -> {dgettext("ui", "已跳过"), :subtle, "lucide-skip-forward"}
      "started" -> {dgettext("ui", "进行中"), :brand, "lucide-loader-circle"}
      "succeeded" -> {dgettext("ui", "成功"), :success, "lucide-check"}
      "failed" -> {dgettext("ui", "失败"), :danger, "lucide-x"}
      "cancelled" -> {dgettext("ui", "已取消"), :subtle, "lucide-slash"}
      other -> {other, :muted, "lucide-circle-question-mark"}
    end
  end

  @doc "Text of a record's reason code (D14); unknown codes are shown as they are."
  def reason_text(nil), do: nil

  def reason_text(reason), do: Map.get(reason_texts(), to_string(reason), to_string(reason))

  defp reason_texts do
    %{
      "overlap" => dgettext("ui", "上一次还在进行，已跳过"),
      "superseded" => dgettext("ui", "被更新的请求取代"),
      "missed" => dgettext("ui", "服务停机错过"),
      "unauthorized" => dgettext("ui", "授权来源无权触发目标"),
      "initiator_left" => dgettext("ui", "授权来源已离开工作区"),
      "agent_archived" => dgettext("ui", "目标已归档"),
      "agent_disabled" => dgettext("ui", "目标已停用"),
      "squad_disabled" => dgettext("ui", "小队已停用"),
      "no_runtime" => dgettext("ui", "目标没有绑定运行时"),
      "runtime_disabled" => dgettext("ui", "目标的运行时已禁用"),
      "project_archived" => dgettext("ui", "项目已归档"),
      "run_failed" => dgettext("ui", "运行失败"),
      "task_rejected" => dgettext("ui", "任务被拒绝"),
      "stopped" => dgettext("ui", "运行被人停止"),
      "task_cancelled" => dgettext("ui", "任务已撤销"),
      "task_deleted" => dgettext("ui", "任务已被删除"),
      "reassigned" => dgettext("ui", "任务被改派"),
      "autopilot_disabled" => dgettext("ui", "自动化已停用"),
      "config_changed" => dgettext("ui", "配置已修改")
    }
  end

  @doc "Why an autopilot is disabled (`disabled_reason`)."
  def disabled_text(nil), do: nil

  def disabled_text(reason),
    do: Map.get(disabled_texts(), to_string(reason), to_string(reason))

  defp disabled_texts do
    %{
      "manual" => dgettext("ui", "已手动停用"),
      "consecutive_failures" => dgettext("ui", "连续失败 5 次后停用"),
      "unauthorized" => dgettext("ui", "授权来源无权触发目标，已停用"),
      "initiator_left" => dgettext("ui", "授权来源已离开工作区，已停用"),
      "agent_archived" => dgettext("ui", "目标已归档，已停用"),
      "project_archived" => dgettext("ui", "项目已归档，已停用")
    }
  end

  @doc "Why the next trigger will fail (`warnings`)."
  def warning_text(code), do: Map.get(warning_texts(), to_string(code), to_string(code))

  defp warning_texts do
    %{
      "unauthorized" => dgettext("ui", "授权来源无权触发目标"),
      "agent_archived" => dgettext("ui", "目标已归档"),
      "agent_disabled" => dgettext("ui", "目标已停用"),
      "squad_disabled" => dgettext("ui", "小队已停用"),
      "no_runtime" => dgettext("ui", "目标没有绑定运行时"),
      "runtime_disabled" => dgettext("ui", "目标的运行时已禁用"),
      "project_archived" => dgettext("ui", "项目已归档"),
      "daemon_too_old" => dgettext("ui", "目标所在机器的守护进程版本过旧，不能在仓库里运行")
    }
  end

  @doc "The first line of `text`, or nil."
  def first_line(nil), do: nil

  def first_line(text) do
    text |> String.trim() |> String.split("\n", parts: 2) |> hd() |> String.slice(0, 200)
  end

  @doc "The actor map of a target (`%{name, kind}`) for `actor_chip/1`."
  def target_actor(%{name: name, kind: kind}),
    do: %{name: name, kind: if(to_string(kind) == "squad", do: :squad, else: :agent)}

  def target_actor(_), do: %{name: "—", kind: :system}

  ## Components

  @doc "Status badge of a record."
  attr :status, :any, required: true
  attr :class, :any, default: nil
  attr :rest, :global

  def record_badge(assigns) do
    {label, tone, icon} = record_status(assigns.status)
    assigns = assign(assigns, label: label, tone: tone, icon: icon)

    ~H"""
    <.badge tone={@tone} class={@class} data-record-status={to_string(@status)} {@rest}>
      <.icon name={@icon} class="size-3.5" />
      {@label}
    </.badge>
    """
  end

  @doc "The task (ident link) or run (「运行 #id」) a record produced."
  attr :record, :map, required: true
  attr :slug, :string, required: true

  def record_result_link(assigns) do
    ~H"""
    <.task_id_link :if={@record[:task]} ident={@record.task} workspace={@slug} />
    <.link
      :if={!@record[:task] && @record[:run_id]}
      navigate={"/w/#{@slug}/runs/#{@record.run_id}"}
      class="text-label text-fg-muted hover:text-brand-fg"
      data-run-link
    >
      {dgettext("ui", "运行 #%{id}", id: @record.run_id)}
    </.link>
    """
  end

  @doc """
  The enable switch. With `reason` it is read-only and explains why; otherwise a click
  sends `event` with the autopilot id.
  """
  attr :id, :string, required: true
  attr :autopilot_id, :any, required: true
  attr :on, :boolean, required: true
  attr :reason, :string, default: nil
  attr :event, :string, default: "toggle"

  def enable_switch(assigns) do
    ~H"""
    <span class="hm-tooltip-host relative inline-flex" phx-click={%JS{}}>
      <button
        id={@id}
        type="button"
        role="switch"
        aria-checked={to_string(@on)}
        aria-label={dgettext("ui", "启用")}
        aria-disabled={@reason && "true"}
        aria-describedby={@reason && "#{@id}-reason"}
        data-readonly={@reason && "true"}
        phx-click={!@reason && JS.push(@event, value: %{id: @autopilot_id})}
        class={[
          "relative inline-flex h-5 w-9 shrink-0 items-center rounded-full border transition-colors",
          if(@on, do: "border-brand bg-brand", else: "border-border-strong bg-hover"),
          if(@reason, do: "cursor-not-allowed opacity-60", else: "cursor-pointer")
        ]}
      >
        <span class={[
          "inline-block size-3.5 rounded-full bg-surface shadow-popover transition-transform",
          if(@on, do: "translate-x-4", else: "translate-x-0.5")
        ]} />
      </button>
      <span :if={@reason} id={"#{@id}-reason"} role="tooltip" class={tooltip_class(:bottom)}>
        {@reason}
      </span>
    </span>
    """
  end
end
