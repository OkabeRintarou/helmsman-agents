defmodule HelmsmanWeb.CollabComponents do
  @moduledoc """
  Pieces of the collaboration UI (add-collaboration-ui D2): blocking and link texts,
  epic progress, and what a feedback record triggered (dispatch outcomes, steering
  state, mentions that triggered nothing). Pure: the pages own the data.
  """
  use HelmsmanWeb, :html

  alias HelmsmanWeb.Components.Status
  alias HelmsmanWeb.{RunComponents, Url}

  ## Blocking (D3)

  @doc "What a prerequisite waits for (`waiting_for` of a link), as a short phrase."
  @spec waiting_for_text(String.t() | atom() | nil) :: String.t()
  def waiting_for_text(w) when w in ["status", :status], do: dgettext("ui", "未完成")
  def waiting_for_text(w) when w in ["run", :run], do: dgettext("ui", "还有运行在进行")
  def waiting_for_text(w) when w in ["merge", :merge], do: dgettext("ui", "代码还没合并")
  def waiting_for_text(w) when w in ["steps", :steps], do: dgettext("ui", "有步骤还没落地")
  def waiting_for_text(_w), do: dgettext("ui", "未满足")

  @doc "The unsatisfied prerequisites of a task detail: `[%{task, waiting_for}]`."
  @spec blockers(map()) :: [map()]
  def blockers(detail) do
    for %{type: "depends_on", direction: "out", waiting_for: w} = link <- links(detail),
        w != nil,
        do: %{task: link.task, waiting_for: w}
  end

  @doc "The tasks that replace a task detail (`replaces` links coming in)."
  @spec replacers(map()) :: [String.t()]
  def replacers(detail),
    do: for(%{type: "replaces", direction: "in", task: t} <- links(detail), do: t)

  @doc "Why 开始 is disabled for a blocked task (nil when it is not blocked)."
  @spec start_lock(map()) :: String.t() | nil
  def start_lock(%{blocked: true} = detail) do
    case blockers(detail) do
      [] ->
        dgettext("ui", "有未满足的前置任务，前置任务满足后才能开始")

      list ->
        dgettext("ui", "被 %{tasks} 阻塞，前置任务满足后才能开始", tasks: Enum.map_join(list, "、", & &1.task))
    end
  end

  def start_lock(_detail), do: nil

  @doc "Why 恢复 is disabled for a replaced task (nil when nothing replaces it)."
  @spec restore_lock(map()) :: String.t() | nil
  def restore_lock(detail) do
    case replacers(detail) do
      [] -> nil
      ids -> replaced_text(ids)
    end
  end

  @doc "「已被 X 替代；…」"
  def replaced_text(ids),
    do: dgettext("ui", "已被 %{tasks} 替代；先在关联中删除替代关联，才能恢复", tasks: Enum.join(ids, "、"))

  @doc "The tooltip of the 被阻塞 badge: one 「<ID> <what>」 per blocker."
  @spec blocked_tooltip(map()) :: String.t()
  def blocked_tooltip(detail) do
    case blockers(detail) do
      [] ->
        dgettext("ui", "有未满足的前置任务")

      list ->
        dgettext("ui", "在等：%{items}",
          items: Enum.map_join(list, "；", &"#{&1.task} #{waiting_for_text(&1.waiting_for)}")
        )
    end
  end

  defp links(detail), do: Map.get(detail, :links) || []

  attr :task, :map, required: true
  attr :anchor, :string, default: "#task-links"

  @doc "The 被阻塞 badge of the task page header; rendered only for a blocked task."
  def blocked_badge(assigns) do
    assigns = assign(assigns, :text, blocked_tooltip(assigns.task))

    ~H"""
    <a
      :if={@task.blocked}
      id="task-blocked"
      href={@anchor}
      aria-describedby="task-blocked-tip"
      class="inline-flex rounded-badge"
    >
      <.tooltip id="task-blocked-tip" text={@text}>
        <.badge tone={:warning}>
          <.icon name="lucide-octagon-pause" class="size-3.5" />{dgettext("ui", "被阻塞")}
        </.badge>
      </.tooltip>
    </a>
    """
  end

  ## Links (D4)

  @groups [
    {"depends-out", "depends_on", "out"},
    {"depends-in", "depends_on", "in"},
    {"replaces-out", "replaces", "out"},
    {"replaces-in", "replaces", "in"}
  ]

  @doc "The link groups that are not empty, in display order: `[{key, title, links}]`."
  @spec link_groups([map()]) :: [{String.t(), String.t(), [map()]}]
  def link_groups(links) do
    for {key, type, direction} <- @groups,
        items = Enum.filter(links, &(&1.type == type and &1.direction == direction)),
        items != [],
        do: {key, group_title(key), items}
  end

  @doc "Title of a link group / label of a relation choice."
  def group_title("depends-out"), do: dgettext("ui", "依赖于")
  def group_title("depends-in"), do: dgettext("ui", "被依赖")
  def group_title("replaces-out"), do: dgettext("ui", "替代了")
  def group_title("replaces-in"), do: dgettext("ui", "被替代")

  @doc "The relation choices of the add-link panel: `[{label, key}]`."
  def relation_options do
    [
      {dgettext("ui", "依赖于（本任务等它）"), "depends-out"},
      {dgettext("ui", "被依赖（它等本任务）"), "depends-in"},
      {dgettext("ui", "替代（本任务接手它）"), "replaces-out"},
      {dgettext("ui", "被替代（它接手本任务）"), "replaces-in"}
    ]
  end

  @doc """
  `{type, from, to}` of a relation choice between the task `own` and the picked task
  `other`; nil for an unknown choice.
  """
  @spec relation(String.t(), String.t(), String.t()) :: {String.t(), String.t(), String.t()} | nil
  def relation("depends-out", own, other), do: {"depends_on", own, other}
  def relation("depends-in", own, other), do: {"depends_on", other, own}
  def relation("replaces-out", own, other), do: {"replaces", own, other}
  def relation("replaces-in", own, other), do: {"replaces", other, own}
  def relation(_key, _own, _other), do: nil

  @doc "The group key of a link (`depends-out`, …)."
  def group_key(%{type: "depends_on", direction: d}), do: "depends-" <> d
  def group_key(%{type: "replaces", direction: d}), do: "replaces-" <> d

  @doc """
  What adding the relation will do (D5): `{:info | :warning, text}`. `from` and `to` are
  `%{id, status}` of the two ends.
  """
  def consequence("depends_on", from, to) do
    {:info,
     dgettext(
       "ui",
       "%{a} 要等 %{b} 满足（完成、没有进行中的运行、代码已合并）才能开始；指派给托管 Agent 的运行会等待。",
       a: from.id,
       b: to.id
     )}
  end

  def consequence("replaces", _from, %{status: status} = to) when status in ~w(new in_progress) do
    {:warning,
     dgettext(
       "ui",
       "%{b} 现在是%{status}，建立后会被自动撤销；它上面进行中的运行不会停止，需要时请手动停止。",
       b: to.id,
       status: Status.task_status(status).label
     )}
  end

  def consequence("replaces", _from, to) do
    {:info,
     dgettext("ui", "%{b} 是%{status}，只记录关联，不改变状态。",
       b: to.id,
       status: Status.task_status(to.status).label
     )}
  end

  @doc "The text of the unlink confirmation for a link seen from the task `own`."
  def unlink_text(%{type: "depends_on"} = link, own) do
    {a, b} = ends(link, own)

    dgettext("ui", "%{a} 不再等 %{b}。%{a} 上等待中的运行若只等它，会开始排队。", a: a, b: b)
  end

  def unlink_text(%{type: "replaces"} = link, own) do
    {a, b} = ends(link, own)
    dgettext("ui", "%{a} 不再替代 %{b}。%{b} 保持当前状态（已撤销的不会自动恢复）。", a: a, b: b)
  end

  @doc "`{from, to}` of a link of the task `own`."
  def ends(%{direction: "out", task: other}, own), do: {own, other}
  def ends(%{direction: "in", task: other}, own), do: {other, own}

  @doc "The text of a `Helmsman.Links` error, or nil for an unexpected one."
  def link_error({:cycle, path}),
    do: dgettext("ui", "会形成循环：%{path}", path: Enum.join(path, " → "))

  def link_error(:self_link), do: dgettext("ui", "任务不能关联自己")
  def link_error({:not_found, id}), do: dgettext("ui", "任务 %{id} 不存在", id: id)
  def link_error(:not_found), do: dgettext("ui", "任务不存在")
  def link_error(:forbidden), do: dgettext("ui", "没有权限执行此操作")
  def link_error({:forbidden, _}), do: dgettext("ui", "没有权限执行此操作")
  def link_error(_reason), do: nil

  ## Epics (D7)

  @doc "Text of an epic field error from the domain (English) or nil."
  def epic_error("not found"), do: dgettext("ui", "Epic 不存在")
  def epic_error("is not an epic"), do: dgettext("ui", "不是 Epic")
  def epic_error("an epic cannot belong to another epic"), do: dgettext("ui", "Epic 不能属于另一个 Epic")
  def epic_error(_message), do: nil

  attr :id, :string, required: true
  attr :progress, :map, required: true, doc: "%{total, done}"
  attr :class, :any, default: nil

  @doc "An accessible progress bar of an epic's steps."
  def progress_bar(assigns) do
    assigns = assign(assigns, :pct, percent(assigns.progress))

    ~H"""
    <div
      id={@id}
      role="progressbar"
      aria-valuemin="0"
      aria-valuemax={@progress.total}
      aria-valuenow={@progress.done}
      aria-label={
        dgettext("ui", "已完成 %{done} / %{total}", done: @progress.done, total: @progress.total)
      }
      class={["h-1.5 w-full overflow-hidden rounded-full bg-hover", @class]}
    >
      <div
        class="h-full rounded-full bg-success transition-[width] duration-300 motion-reduce:transition-none"
        style={"width: #{@pct}%"}
      />
    </div>
    """
  end

  attr :progress, :map, default: nil
  attr :bar, :boolean, default: true
  attr :class, :any, default: nil
  attr :rest, :global

  @doc "Compact 「done/total」, with a small bar unless `bar` is false (lists, the 所属 Epic row)."
  def epic_progress(%{progress: nil} = assigns), do: ~H""

  def epic_progress(assigns) do
    assigns = assign(assigns, :pct, percent(assigns.progress))

    ~H"""
    <span
      class={["inline-flex flex-none items-center gap-1.5", @class]}
      data-progress={"#{@progress.done}/#{@progress.total}"}
      title={dgettext("ui", "已完成 %{done} / %{total}", done: @progress.done, total: @progress.total)}
      {@rest}
    >
      <span :if={@bar} class="h-1 w-10 overflow-hidden rounded-full bg-hover" aria-hidden="true">
        <span class="block h-full rounded-full bg-success" style={"width: #{@pct}%"} />
      </span>
      <span class="font-mono text-caption text-fg-muted tabular-nums">
        {@progress.done}/{@progress.total}
      </span>
    </span>
    """
  end

  defp percent(%{total: total, done: done}) when is_integer(total) and total > 0,
    do: round(done * 100 / total)

  defp percent(_progress), do: 0

  @doc "The status counts of a progress that are not zero, in status order: `[{status, n}]`."
  def status_counts(%{by_status: by_status}) do
    for status <- Status.task_statuses(),
        n = Map.get(by_status, status, 0),
        n > 0,
        do: {status, n}
  end

  def status_counts(_progress), do: []

  attr :kind, :string, default: "epic"

  @doc "The small 「Epic」 kind badge."
  def epic_badge(assigns) do
    ~H"""
    <.badge :if={@kind == "epic"} tone={:review} data-kind="epic">
      <.icon name="lucide-list-tree" class="size-3" />Epic
    </.badge>
    """
  end

  ## What a feedback record triggered (D9)

  @doc """
  Why a dispatch item started nothing, as seen by any reader: the person who triggered
  is the author (or the authorizer of the run that wrote it), not the reader.
  """
  @spec dispatch_reason(String.t(), term()) :: String.t()
  def dispatch_reason(_agent, reason) when reason in ["unauthorized", :unauthorized],
    do: dgettext("ui", "触发者无权触发它")

  def dispatch_reason(agent, reason),
    do: RunComponents.skip_reason(agent, reason) || dgettext("ui", "没有启动")

  @doc "`%{agent => reason}` of the mentions of a record that started nothing."
  @spec mention_notes([map()] | nil) :: %{String.t() => String.t()}
  def mention_notes(dispatch) do
    for %{trigger: "mention", result: "skipped", agent: agent} = item <- dispatch || [],
        is_binary(agent),
        not covered?(item),
        into: %{},
        do: {agent, dispatch_reason(agent, item.reason)}
  end

  @doc """
  The steering state of a record: `{:acked | :sent, steer}`, `{:skipped, item}`,
  `{:queued, item}` or nil (D9, first that holds).
  """
  def steer_state(%{steer: %{acked_at: at} = steer}) when at != nil, do: {:acked, steer}
  def steer_state(%{steer: %{} = steer}), do: {:sent, steer}

  def steer_state(entry) do
    case Enum.find(Map.get(entry, :dispatch) || [], &(&1.trigger == "steer")) do
      %{result: "skipped"} = item -> {:skipped, item}
      %{} = item -> {:queued, item}
      nil -> nil
    end
  end

  attr :entry, :map, required: true
  attr :dom_id, :string, required: true
  attr :uri, :string, default: nil, doc: "page URI: runs link to `?run=<id>`; nil: no links"

  @doc "The triggers of a record (steering excluded), one chip each."
  def dispatch_line(assigns) do
    items =
      for item <- Map.get(assigns.entry, :dispatch) || [],
          item.trigger != "steer",
          is_binary(item.agent),
          do: item

    assigns =
      assign(assigns,
        items: Enum.map(items, &Map.put(&1, :covered_by, covered_by(&1, items)))
      )

    ~H"""
    <ul
      :if={@items != []}
      id={"#{@dom_id}-dispatch"}
      aria-label={dgettext("ui", "触发")}
      class="mt-2 flex flex-wrap gap-1.5"
    >
      <li
        :for={{item, i} <- Enum.with_index(@items)}
        id={"#{@dom_id}-dispatch-#{i}"}
        data-agent={item.agent}
        data-result={item.result}
        data-skipped={item.result == "skipped" && !item.covered_by && "true"}
        data-covered={item.covered_by && "true"}
        class={[
          "inline-flex max-w-full items-center gap-1 rounded-badge border px-1.5 py-0.5 text-caption",
          if(item.result == "skipped" and !item.covered_by,
            do: "border-dashed border-border text-fg-subtle",
            else: "border-border text-fg-muted"
          )
        ]}
      >
        <.icon
          name={
            if(item.result == "skipped" and !item.covered_by,
              do: "lucide-circle-slash",
              else: "lucide-bot"
            )
          }
          class="size-3 flex-none"
        />
        <span>{RunComponents.trigger_kind(%{kind: item.trigger})}</span>
        <span aria-hidden="true">·</span>
        <.link
          :if={@uri && item.run_id && item.result != "skipped"}
          patch={Url.put_params(@uri, %{run: item.run_id})}
          class="font-medium text-fg hover:text-brand-fg hover:underline"
        >
          {item_name(item)}
        </.link>
        <span :if={!(@uri && item.run_id && item.result != "skipped")}>
          <span class="font-medium">{item_name(item)}</span><span :if={item.covered_by}>：{covered_text(
            item.covered_by
          )}</span><span :if={item.result == "skipped" and !item.covered_by}>：{dispatch_reason(
            item.agent,
            item.reason
          )}</span>
        </span>
        <span :if={item.result == "deferred"}>{dgettext("ui", "等前置任务满足后开始")}</span>
      </li>
    </ul>
    """
  end

  # add-nested-feedback-replies D12: a mention skipped because the same record already
  # woke its agent (an answer or a callback that was queued or merged).
  defp covered?(%{result: "skipped", reason: reason}), do: reason in ["covered", :covered]
  defp covered?(_item), do: false

  # The trigger kind that woke the covered mention's agent, nil when not covered.
  defp covered_by(item, items) do
    if covered?(item) do
      Enum.find_value(items, "answer", fn other ->
        (other.agent == item.agent and other.result in ["queued", "merged"] and
           other.trigger != "mention") && other.trigger
      end)
    end
  end

  defp covered_text("requested"), do: dgettext("ui", "已由这条记录的回调唤醒")
  defp covered_text(_answer), do: dgettext("ui", "已由这条记录的回答唤醒")

  # A squad's leader run reads「web-team（keel/lead）」.
  defp item_name(%{squad: squad, agent: agent}) when is_binary(squad), do: "#{squad}（#{agent}）"
  defp item_name(item), do: item.agent

  attr :entry, :map, required: true
  attr :dom_id, :string, required: true

  @doc "The steering state line of a record (nothing when it steered no run)."
  def steer_line(assigns) do
    assigns = assign(assigns, :state, steer_state(assigns.entry))

    ~H"""
    <p
      :if={@state}
      id={"#{@dom_id}-steer"}
      data-steer={elem(@state, 0)}
      class={[
        "mt-2 flex flex-wrap items-center gap-1 text-caption",
        if(elem(@state, 0) == :skipped, do: "text-fg-subtle", else: "text-fg-muted")
      ]}
    >
      <%= case @state do %>
        <% {:acked, steer} -> %>
          <.icon name="lucide-check-check" class="size-3.5 text-success" />
          {dgettext("ui", "已送达运行 #%{run}（%{agent}）", run: steer.run_id, agent: steer.agent)}
          <.relative_time id={"#{@dom_id}-steer-at"} at={steer.acked_at} class="text-fg-subtle" />
        <% {:sent, steer} -> %>
          <.icon name="lucide-send" class="size-3.5" />
          {dgettext("ui", "已发给运行 #%{run}，等 %{agent} 接收", run: steer.run_id, agent: steer.agent)}
        <% {:skipped, item} -> %>
          <.icon name="lucide-circle-slash" class="size-3.5" />
          {dgettext("ui", "没有插话 %{agent}：%{reason}",
            agent: item.agent,
            reason: dispatch_reason(item.agent, item.reason)
          )}
        <% {:queued, item} -> %>
          <.icon name="lucide-clock" class="size-3.5" />
          {queued_text(item)}
      <% end %>
    </p>
    """
  end

  defp queued_text(%{steer_run_id: run, agent: agent}) when run != nil,
    do: dgettext("ui", "%{agent} 会在运行 #%{run} 结束后处理", agent: agent, run: run)

  defp queued_text(%{agent: agent}),
    do: dgettext("ui", "%{agent} 会在当前运行结束后处理", agent: agent)

  ## Mention completion (D9)

  @doc """
  The mention candidates of a feedback editor with a `note` (and `muted`) on the agents
  a mention would not start: unavailable managed agents (`availability`, see
  `HelmsmanWeb.RunData.availability/1`) and external agents.
  """
  @spec mention_candidates([map()], map()) :: [map()]
  def mention_candidates(candidates, availability) do
    Enum.map(candidates, fn candidate ->
      case mention_note(candidate, availability[candidate.name]) do
        nil -> candidate
        note -> Map.merge(candidate, %{note: note, muted: true})
      end
    end)
  end

  defp mention_note(%{name: name, kind: kind}, %{kind: :squad, result: {:skipped, _}} = entry)
       when kind in ["squad", :squad],
       do:
         dgettext("ui", "@ 不会启动它：%{reason}",
           reason: HelmsmanWeb.TaskData.unavailable_text(name, entry)
         )

  defp mention_note(%{kind: kind}, _availability) when kind not in ["agent", :agent], do: nil

  defp mention_note(%{name: name}, %{result: {:skipped, _} = result}),
    do:
      dgettext("ui", "@ 不会启动它：%{reason}", reason: RunComponents.unavailable_reason(name, result))

  defp mention_note(_candidate, %{}), do: nil

  defp mention_note(%{managed?: false}, nil), do: dgettext("ui", "外接 Agent，@ 不会唤醒它")
  defp mention_note(_candidate, nil), do: nil
end
