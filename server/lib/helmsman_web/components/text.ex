defmodule HelmsmanWeb.Components.Text do
  @moduledoc """
  Text-level components: `task_id_link/1`, `relative_time/1` (with the colocated
  `LocalTime` hook), `copy_button/1` (colocated `Copy` hook), `secret_once/1` and
  `spark_bars/1`.
  """
  use Phoenix.Component
  use Gettext, backend: HelmsmanWeb.Gettext

  import HelmsmanWeb.CoreComponents, only: [icon: 1]

  @doc """
  `KEY-N` in a monospace font linking to `/w/<slug>/t/<KEY-N>`, optionally followed by
  the (truncated) title. Cancelled tasks are struck through.
  """
  attr :ident, :string, required: true
  attr :workspace, :string, required: true, doc: "workspace slug"
  attr :title, :string, default: nil
  attr :status, :any, default: nil
  attr :class, :any, default: nil

  def task_id_link(assigns) do
    assigns =
      assign(assigns, :cancelled?, String.downcase(to_string(assigns.status)) == "cancelled")

    ~H"""
    <.link
      navigate={"/w/#{@workspace}/t/#{@ident}"}
      class={["group inline-flex min-w-0 max-w-full items-baseline gap-2", @class]}
    >
      <span class={[
        "font-mono text-label text-fg-muted group-hover:text-brand-fg",
        @cancelled? && "line-through"
      ]}>
        {@ident}
      </span>
      <span :if={@title} class="truncate text-body text-fg group-hover:underline">{@title}</span>
    </.link>
    """
  end

  @doc """
  Relative time ("刚刚", "3 分钟前", "昨天", a date after 7 days) inside
  `<time datetime>`. The `LocalTime` hook sets the title to the absolute time in the
  browser's time zone and refreshes the text every 60 seconds.
  """
  attr :id, :string, required: true
  attr :at, DateTime, required: true
  attr :now, DateTime, default: nil, doc: "reference time (defaults to now; for tests)"
  attr :class, :any, default: nil

  def relative_time(assigns) do
    now = assigns.now || DateTime.utc_now()

    assigns =
      assign(assigns, text: relative_text(assigns.at, now), iso: DateTime.to_iso8601(assigns.at))

    ~H"""
    <time
      id={@id}
      datetime={@iso}
      title={Calendar.strftime(@at, "%Y-%m-%d %H:%M UTC")}
      phx-hook=".LocalTime"
      data-just-now={dgettext("ui", "刚刚")}
      data-minutes={dgettext("ui", "%{n} 分钟前", n: "{n}")}
      data-hours={dgettext("ui", "%{n} 小时前", n: "{n}")}
      data-yesterday={dgettext("ui", "昨天")}
      data-days={dgettext("ui", "%{n} 天前", n: "{n}")}
      class={["whitespace-nowrap", @class]}
    >
      {@text}
    </time>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".LocalTime">
      const pad = n => String(n).padStart(2, "0")
      const fmtDate = d => `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`

      export default {
        mounted() { this.render(); this.timer = setInterval(() => this.render(), 60_000) },
        updated() { this.render() },
        destroyed() { clearInterval(this.timer) },
        render() {
          const at = new Date(this.el.getAttribute("datetime"))
          if (isNaN(at)) return
          const d = this.el.dataset
          const secs = (Date.now() - at.getTime()) / 1000
          let text
          if (secs < 60) text = d.justNow
          else if (secs < 3600) text = d.minutes.replace("{n}", Math.floor(secs / 60))
          else if (secs < 86400) text = d.hours.replace("{n}", Math.floor(secs / 3600))
          else if (secs < 2 * 86400) text = d.yesterday
          else if (secs < 7 * 86400) text = d.days.replace("{n}", Math.floor(secs / 86400))
          else text = fmtDate(at)
          this.el.textContent = text
          this.el.title = `${fmtDate(at)} ${pad(at.getHours())}:${pad(at.getMinutes())}`
        }
      }
    </script>
    """
  end

  @doc "Relative text for `at` seen from `now` (server-side rendering, UTC dates)."
  def relative_text(%DateTime{} = at, %DateTime{} = now) do
    secs = DateTime.diff(now, at, :second)

    cond do
      secs < 60 -> dgettext("ui", "刚刚")
      secs < 3600 -> dgettext("ui", "%{n} 分钟前", n: div(secs, 60))
      secs < 86_400 -> dgettext("ui", "%{n} 小时前", n: div(secs, 3600))
      secs < 2 * 86_400 -> dgettext("ui", "昨天")
      secs < 7 * 86_400 -> dgettext("ui", "%{n} 天前", n: div(secs, 86_400))
      true -> Calendar.strftime(at, "%Y-%m-%d")
    end
  end

  @doc """
  Copies `text` to the clipboard. On success the icon briefly turns into a check and
  "已复制" is announced; if the clipboard is unavailable the text (or the element in
  `target`) is selected and the user is asked to copy manually.
  """
  attr :id, :string, required: true
  attr :text, :string, required: true
  attr :label, :string, default: nil, doc: "accessible name (defaults to 复制)"
  attr :target, :string, default: nil, doc: "selector of the element to select on failure"
  attr :class, :any, default: nil

  def copy_button(assigns) do
    ~H"""
    <span class={["relative inline-flex items-center gap-1", @class]}>
      <button
        id={@id}
        type="button"
        phx-hook=".Copy"
        data-copy={@text}
        data-copy-target={@target}
        data-copied={dgettext("ui", "已复制")}
        data-failed={dgettext("ui", "无法访问剪贴板，已选中文本，请手动复制")}
        aria-label={@label || dgettext("ui", "复制")}
        class="inline-flex size-7 items-center justify-center rounded-field text-fg-muted hover:bg-hover hover:text-fg"
      >
        <.icon name="lucide-copy" class="size-4" data-copy-icon />
        <.icon name="lucide-check" class="hidden size-4 text-success" data-copy-done />
      </button>
      <span id={"#{@id}-status"} role="status" class="text-caption text-fg-muted empty:hidden"></span>
    </span>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".Copy">
      export default {
        mounted() {
          this.status = document.getElementById(`${this.el.id}-status`)
          this.el.addEventListener("click", () => this.copy())
        },
        destroyed() { clearTimeout(this.timer) },
        async copy() {
          const text = this.el.dataset.copy
          try {
            await navigator.clipboard.writeText(text)
            this.flash(this.el.dataset.copied, true)
          } catch (_e) {
            this.selectFallback()
            this.flash(this.el.dataset.failed, false)
          }
        },
        selectFallback() {
          const sel = this.el.dataset.copyTarget
          const target = sel && document.querySelector(sel)
          if (!target) return
          const range = document.createRange()
          range.selectNodeContents(target)
          const selection = window.getSelection()
          selection.removeAllRanges()
          selection.addRange(range)
        },
        flash(message, ok) {
          const icon = this.el.querySelector("[data-copy-icon]")
          const done = this.el.querySelector("[data-copy-done]")
          if (ok) { icon.classList.add("hidden"); done.classList.remove("hidden") }
          this.status.textContent = message
          clearTimeout(this.timer)
          this.timer = setTimeout(() => {
            icon.classList.remove("hidden"); done.classList.add("hidden")
            this.status.textContent = ""
          }, ok ? 2000 : 6000)
        }
      }
    </script>
    """
  end

  @doc """
  Shows a one-time secret (e.g. a freshly created token) in monospace with a copy button
  and a warning. The page must render it only in the response that created or rotated
  the secret.
  """
  attr :id, :string, required: true
  attr :value, :string, required: true
  attr :class, :any, default: nil

  def secret_once(assigns) do
    ~H"""
    <div
      id={@id}
      class={["flex flex-col gap-2 rounded-box border border-warning tint-warning p-3", @class]}
    >
      <p class="flex items-center gap-1.5 text-label font-medium text-warning-fg">
        <.icon name="lucide-triangle-alert" class="size-4" />
        {dgettext("ui", "关闭后将无法再次查看，请立即复制保存。")}
      </p>
      <div class="flex items-center gap-2 rounded-field border border-border bg-surface px-2 py-1">
        <code id={"#{@id}-value"} class="min-w-0 flex-1 break-all font-mono text-label text-fg">
          {@value}
        </code>
        <.copy_button id={"#{@id}-copy"} text={@value} target={"##{@id}-value"} />
      </div>
    </div>
    """
  end

  @doc """
  Inline SVG bar chart of daily values: `points` is a list of `{date, value}`.
  Every non-zero bar has a `<title>日期：数值</title>`; all-zero data draws only the baseline.
  """
  attr :points, :list, required: true
  attr :label, :string, required: true, doc: "accessible summary, e.g. 近 30 天运行次数"
  attr :bar_width, :integer, default: 4
  attr :height, :integer, default: 24
  attr :class, :any, default: nil

  def spark_bars(assigns) do
    gap = 1
    max = assigns.points |> Enum.map(&elem(&1, 1)) |> Enum.max(fn -> 0 end)
    width = max(length(assigns.points) * (assigns.bar_width + gap) - gap, 1)

    bars =
      for {{date, value}, i} <- Enum.with_index(assigns.points), value > 0 do
        h = max(round(value / max * (assigns.height - 1)), 1)

        %{
          x: i * (assigns.bar_width + gap),
          y: assigns.height - 1 - h,
          h: h,
          title: dgettext("ui", "%{date}：%{value}", date: to_string(date), value: value)
        }
      end

    assigns = assign(assigns, width: width, bars: bars)

    ~H"""
    <svg
      viewBox={"0 0 #{@width} #{@height}"}
      width={@width}
      height={@height}
      role="img"
      aria-label={@label}
      class={["text-brand", @class]}
    >
      <line
        x1="0"
        x2={@width}
        y1={@height - 0.5}
        y2={@height - 0.5}
        class="stroke-border-strong"
        stroke-width="1"
      />
      <rect
        :for={bar <- @bars}
        x={bar.x}
        y={bar.y}
        width={@bar_width}
        height={bar.h}
        rx="1"
        class="fill-current"
      >
        <title>{bar.title}</title>
      </rect>
    </svg>
    """
  end
end
