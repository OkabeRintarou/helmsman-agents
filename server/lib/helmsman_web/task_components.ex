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
  An actor reference of a task summary (`%{name, kind}`) as an `actor_chip`. Agents
  take `managed?` / `owner_name` from `agents` (`HelmsmanWeb.TaskData.agent_info/1`);
  without an entry the chip claims neither 托管 nor 外接. `appearance` (the shell's
  `@appearance`) adds the CLI and avatar (`HelmsmanWeb.Appearance.decorate/2`).
  """
  attr :id, :string, default: nil
  attr :actor, :map, default: nil
  attr :agents, :map, default: %{}
  attr :appearance, :map, default: %{}
  attr :compact, :boolean, default: false
  attr :class, :any, default: nil
  attr :slug, :string, default: nil, doc: "workspace slug: a squad links to its page"

  def actor_ref(%{actor: nil} = assigns) do
    ~H"""
    <span class={["text-fg-subtle", @class]}>—</span>
    """
  end

  def actor_ref(%{slug: slug, actor: %{kind: kind, name: name}} = assigns)
      when is_binary(slug) and kind in ["squad", :squad] do
    assigns = assign(assigns, :path, HelmsmanWeb.Url.squad_path(slug, name))

    ~H"""
    <.link navigate={@path} class="min-w-0" data-squad-link>
      <.actor_chip
        id={@id}
        actor={chip_actor(@actor, @agents, @appearance)}
        compact={@compact}
        class={@class}
      />
    </.link>
    """
  end

  def actor_ref(assigns) do
    ~H"""
    <.actor_chip
      id={@id}
      actor={chip_actor(@actor, @agents, @appearance)}
      compact={@compact}
      class={@class}
    />
    """
  end

  defp chip_actor(actor, agents, appearance),
    do: actor |> chip_fields(agents) |> Appearance.decorate(appearance)

  defp chip_fields(%{name: name, kind: kind} = actor, agents)
       when kind in ["agent", :agent, "squad", :squad],
       do: Map.merge(Map.take(actor, [:name, :kind, :state]), Map.get(agents, name, %{}))

  # Unclaimed humans (imported identities) keep the flag for the chip's 未认领 mark.
  defp chip_fields(actor, _agents),
    do:
      actor
      |> Map.take([:name, :kind, :state])
      |> Map.put(:unclaimed, Map.get(actor, :unclaimed, false))

  @doc """
  One history entry (oldest first in the timeline): actor, action (创建了任务, 重新验收
  for `verified → verified`, or `from → to`), relative time, the 自动 mark, the reason
  (a link to its feedback) or else the comment, commits, test result and the verified
  commit (add-github-ui D12). Works with entries without `commits`, `tests`, `auto`,
  `feedback` or `verified_sha`.
  """
  attr :id, :string, required: true
  attr :entry, :map, required: true
  attr :now, DateTime, default: nil
  attr :agents, :map, default: %{}, doc: "see `actor_ref/1`"
  attr :appearance, :map, default: %{}, doc: "see `actor_ref/1`"

  def history_entry(assigns) do
    entry = assigns.entry

    assigns =
      assign(assigns,
        commits: Map.get(entry, :commits) || [],
        tests: Map.get(entry, :tests),
        auto: Map.get(entry, :auto, false) == true,
        comment: Map.get(entry, :comment),
        reason: Map.get(entry, :feedback),
        reason_seq: HelmsmanWeb.FeedbackTimeline.seq_of(Map.get(entry, :feedback)),
        reverified?: entry.from == "verified" and entry.to == "verified",
        verified_sha: entry.to == "verified" && Map.get(entry, :verified_sha)
      )

    ~H"""
    <li id={@id} class="flex flex-col gap-1.5 py-2">
      <div class="flex flex-wrap items-center gap-x-1.5 gap-y-1 text-body">
        <.actor_ref actor={@entry.actor} agents={@agents} appearance={@appearance} />
        <span :if={is_nil(@entry.from)} class="text-fg-muted">{dgettext("ui", "创建了任务")}</span>
        <span :if={@reverified?} data-reverified class="inline-flex items-center gap-1 text-fg-muted">
          <.status_icon status="verified" />{dgettext("ui", "重新验收")}
        </span>
        <span
          :if={@entry.from && !@reverified?}
          class="inline-flex items-center gap-1 text-fg-muted"
        >
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
      <p :if={@reason} data-reason class="text-body text-fg-muted">
        {dgettext("ui", "原因：")}<a
          href={"#feedback-#{@reason_seq}"}
          class="font-mono text-label text-fg-muted hover:text-brand-fg"
        >{@reason}</a>
      </p>
      <p
        :if={!@reason and @comment not in [nil, ""]}
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
      <p :if={@verified_sha} data-verified-sha class="flex items-center gap-1 text-body">
        <span class="text-fg-muted">{dgettext("ui", "验收提交")}</span>
        <code class="font-mono text-label text-fg-muted" title={@verified_sha}>{String.slice(
          @verified_sha,
          0,
          7
        )}</code>
        <.copy_button
          id={"#{@id}-verified-sha"}
          text={@verified_sha}
          label={dgettext("ui", "复制验收提交 %{hash}", hash: @verified_sha)}
        />
      </p>
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
