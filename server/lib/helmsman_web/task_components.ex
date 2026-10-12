defmodule HelmsmanWeb.TaskComponents do
  @moduledoc """
  Function components and helpers of the project and task pages: priority options,
  history entries (design D9), actor references and the task list's label buttons.
  """
  use HelmsmanWeb, :html

  alias HelmsmanWeb.Components.Status

  @doc "Priority options for selects and menus: `[{label, value}]`, high first."
  def priority_options do
    [
      {dgettext("ui", "高"), "high"},
      {dgettext("ui", "中"), "medium"},
      {dgettext("ui", "低"), "low"}
    ]
  end

  @doc "Display name of a priority value."
  def priority_label(priority) do
    case List.keyfind(priority_options(), to_string(priority), 1) do
      {label, _} -> label
      nil -> to_string(priority)
    end
  end

  @doc "Chinese name of a task status."
  def status_label(status), do: Status.task_status(status).label

  @doc """
  Plain-text excerpt: whitespace collapsed, at most `max` characters plus "…".

      iex> HelmsmanWeb.TaskComponents.excerpt("a\\n  b", 10)
      "a b"

      iex> HelmsmanWeb.TaskComponents.excerpt("abcdef", 3)
      "abc…"
  """
  def excerpt(nil, _max), do: ""

  def excerpt(text, max) do
    text = text |> String.replace(~r/\s+/u, " ") |> String.trim()
    if String.length(text) > max, do: String.slice(text, 0, max) <> "…", else: text
  end

  @doc """
  An actor reference of a task summary (`%{name, kind}`) as an `actor_chip`.
  """
  attr :id, :string, default: nil
  attr :actor, :map, default: nil
  attr :compact, :boolean, default: false
  attr :class, :any, default: nil

  def actor_ref(%{actor: nil} = assigns) do
    ~H"""
    <span class={["text-fg-subtle", @class]}>—</span>
    """
  end

  def actor_ref(assigns) do
    ~H"""
    <.actor_chip
      id={@id}
      actor={%{name: @actor.name, kind: @actor.kind}}
      compact={@compact}
      class={@class}
    />
    """
  end

  @doc """
  One history entry (oldest first in the timeline): actor, action (创建了任务 or
  `from → to`), relative time, the 自动 mark, comment, commits and test result.
  Works with entries without `commits`, `tests` or `auto`.
  """
  attr :id, :string, required: true
  attr :entry, :map, required: true
  attr :now, DateTime, default: nil

  def history_entry(assigns) do
    entry = assigns.entry

    assigns =
      assign(assigns,
        commits: Map.get(entry, :commits) || [],
        tests: Map.get(entry, :tests),
        auto: Map.get(entry, :auto, false) == true,
        comment: Map.get(entry, :comment)
      )

    ~H"""
    <li id={@id} class="flex flex-col gap-1.5 py-2">
      <div class="flex flex-wrap items-center gap-x-1.5 gap-y-1 text-body">
        <.actor_ref actor={@entry.actor} />
        <span :if={is_nil(@entry.from)} class="text-fg-muted">{dgettext("ui", "创建了任务")}</span>
        <span :if={@entry.from} class="inline-flex items-center gap-1 text-fg-muted">
          <.status_icon status={@entry.from} />
          <span data-from>{status_label(@entry.from)}</span>
          <.icon name="lucide-arrow-right" class="size-3.5 text-fg-subtle" label="→" />
          <.status_icon status={@entry.to} />
          <span data-to>{status_label(@entry.to)}</span>
        </span>
        <.badge :if={@auto} tone={:info} data-auto>{dgettext("ui", "自动")}</.badge>
        <.relative_time
          :if={@entry[:at]}
          id={"#{@id}-at"}
          at={@entry.at}
          now={@now}
          class="ml-auto text-caption text-fg-subtle"
        />
      </div>
      <p
        :if={@comment not in [nil, ""]}
        data-comment
        class="whitespace-pre-wrap break-words text-body text-fg"
        phx-no-format
      >{@comment}</p>
      <ul
        :if={@commits != []}
        class="flex flex-wrap items-center gap-1"
        aria-label={dgettext("ui", "提交")}
      >
        <li :for={{hash, i} <- Enum.with_index(@commits)} class="inline-flex items-center">
          <code class="font-mono text-label text-fg-muted" title={hash}>{String.slice(hash, 0, 7)}</code>
          <.copy_button
            id={"#{@id}-commit-#{i}"}
            text={hash}
            label={dgettext("ui", "复制提交 %{hash}", hash: hash)}
          />
        </li>
      </ul>
      <div :if={@tests} data-tests class="flex flex-wrap items-center gap-1.5 text-body">
        <.icon
          :if={@tests.passed == true}
          name="lucide-circle-check"
          class="size-4 text-success"
          label={dgettext("ui", "测试通过")}
        />
        <.icon
          :if={@tests.passed != true}
          name="lucide-circle-x"
          class="size-4 text-danger"
          label={dgettext("ui", "测试未通过")}
        />
        <code class="font-mono text-label text-fg">{@tests.command}</code>
        <span :if={@tests[:summary] not in [nil, ""]} class="text-fg-muted">{@tests.summary}</span>
      </div>
    </li>
    """
  end
end
