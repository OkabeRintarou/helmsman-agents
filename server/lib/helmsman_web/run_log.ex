defmodule HelmsmanWeb.RunLog do
  @moduledoc """
  The execution log of a run (spec web-runs 执行记录, design D9, D9a), shared by the task
  page's modal (`?run=<id>`) and the run page. The host LiveView keeps the state in
  `socket.assigns.run_log` and the stream `:run_events`, and forwards `run_log_*` events
  and the run messages to `handle_event/3` / `handle_info/2`.

  Opening checks, subscribes, then reads:

    1. `Runs.get/2` checks the ID (another workspace's run is not found; nothing is
       subscribed).
    2. Members subscribe to `run:<id>`; viewers never do (it carries the events): they
       follow `workspace:<id>:runs` filtered by run ID.
    3. The summary is read again and members read the latest 500 events (R4 `latest`),
       whose `last_seq` is the loaded upper bound.

  Every event committed before step 2 is in step 3's read and every later one is pushed;
  pushed events at or below the loaded bound are dropped and a gap is read from the
  database first. `Application.get_env(:helmsman, :run_log_hook)` (tests only) is called
  with the run ID between steps 1 and 2.

  At most the latest 500 events stay in the stream; after 加载更早的记录 the earlier ones
  loaded on request are kept too (the cap grows with them and with later events). Each
  event is rendered once, when inserted.
  """
  use HelmsmanWeb, :html

  import HelmsmanWeb.RunComponents,
    only: [failure_label: 1, trigger_summary: 1, duration_text: 1, usage_text: 1]

  alias Helmsman.Events
  alias HelmsmanWeb.RunData
  alias Phoenix.LiveView

  @window 500
  @gap_page 1000
  @max_tools 200
  @final ~w(succeeded failed cancelled)

  @doc "Sets up an empty log (closed)."
  def init(socket) do
    socket
    |> Phoenix.Component.assign(:run_log, nil)
    |> LiveView.stream_configure(:run_events, dom_id: &"run-event-#{&1.seq}")
    |> LiveView.stream(:run_events, [])
  end

  @doc "Opens the log of run `id` (closing another one first)."
  def open(socket, id) do
    case socket.assigns.run_log do
      %{id: ^id} -> socket
      _ -> socket |> close() |> do_open(id)
    end
  end

  defp do_open(socket, id) do
    scope = socket.assigns.current_scope

    case RunData.run(scope, id) do
      {:ok, _checked} ->
        if hook = Application.get_env(:helmsman, :run_log_hook), do: hook.(id)
        member? = RunData.can_view_events?(scope)
        topic = subscribe(scope, id, member?)
        read(socket, id, member?, topic)

      {:error, _} ->
        Phoenix.Component.assign(socket, :run_log, %{id: id, state: :not_found, run: nil})
    end
  end

  defp subscribe(_scope, id, true) do
    topic = Events.topic(:run, id)
    Events.subscribe(topic)
    topic
  end

  defp subscribe(scope, _id, false) do
    topic = Events.topic(:workspace_runs, scope.workspace.id)
    Events.subscribe(topic)
    topic
  end

  defp read(socket, id, member?, topic) do
    scope = socket.assigns.current_scope

    log = %{
      id: id,
      state: :viewer,
      run: nil,
      topic: topic,
      member?: member?,
      min_seq: nil,
      max_seq: 0,
      cap: @window,
      tools: %{},
      tool_order: []
    }

    log =
      case RunData.run(scope, id) do
        {:ok, run} -> %{log | run: run}
        {:error, _} -> log
      end

    if member? do
      case RunData.events(scope, id, latest: true, limit: @window) do
        {:ok, %{pruned: true}} ->
          Phoenix.Component.assign(socket, :run_log, %{log | state: :pruned})

        {:ok, %{events: events, last_seq: last_seq}} ->
          log = %{log | state: :events, max_seq: last_seq, min_seq: first_seq(events, last_seq)}
          insert(socket, log, events)

        {:error, _} ->
          Phoenix.Component.assign(socket, :run_log, %{log | state: :unavailable})
      end
    else
      Phoenix.Component.assign(socket, :run_log, log)
    end
  end

  defp first_seq([], last_seq), do: last_seq + 1
  defp first_seq([first | _], _last_seq), do: first.seq

  @doc "Closes the log: unsubscribes and empties the stream."
  def close(%{assigns: %{run_log: nil}} = socket), do: socket

  def close(socket) do
    if topic = socket.assigns.run_log[:topic],
      do: Phoenix.PubSub.unsubscribe(Helmsman.PubSub, topic)

    socket
    |> Phoenix.Component.assign(:run_log, nil)
    |> LiveView.stream(:run_events, [], reset: true)
  end

  @doc "`run_log_earlier`: the 500 events before the earliest loaded one."
  def handle_event(
        "run_log_earlier",
        _params,
        %{assigns: %{run_log: %{state: :events} = log}} = socket
      ) do
    if log.min_seq > 1 do
      case RunData.events(socket.assigns.current_scope, log.id,
             before_seq: log.min_seq,
             limit: @window
           ) do
        {:ok, %{events: [_ | _] = events}} ->
          log = %{log | min_seq: hd(events).seq, cap: log.cap + length(events)}
          views = Enum.map(events, &view(&1, log.tools))

          socket
          |> Phoenix.Component.assign(:run_log, log)
          |> LiveView.stream(:run_events, Enum.reverse(views), at: 0, limit: -log.cap)

        _ ->
          socket
      end
    else
      socket
    end
  end

  def handle_event(_event, _params, socket), do: socket

  @doc """
  Handles `{:run_events, id, events}` and `{:run_updated, summary}` of the open run:
  `{:ok, socket}`, or `:ignore` when the message is not about it.
  """
  def handle_info(
        {:run_events, id, events},
        %{assigns: %{run_log: %{id: id, state: :events} = log}} = socket
      ) do
    fresh = Enum.reject(events, &(&1.seq <= log.max_seq))

    case fresh do
      [] -> {:ok, socket}
      [first | _] when first.seq > log.max_seq + 1 -> {:ok, fill_gap(socket, log, fresh)}
      _ -> {:ok, insert(socket, log, fresh)}
    end
  end

  def handle_info({:run_events, id, _events}, %{assigns: %{run_log: %{id: id}}} = socket),
    do: {:ok, socket}

  def handle_info(
        {:run_updated, %{id: id} = summary},
        %{assigns: %{run_log: %{id: id} = log}} = socket
      ) do
    if log.run == nil or DateTime.compare(summary.updated_at, log.run.updated_at) != :lt do
      run = refreshed(socket, log, summary)
      {:ok, Phoenix.Component.assign(socket, :run_log, %{log | run: run})}
    else
      {:ok, socket}
    end
  end

  def handle_info(_message, _socket), do: :ignore

  # A run that ended: read it again for `error` (member and above).
  defp refreshed(socket, %{member?: true}, %{status: status} = summary) when status in @final do
    case RunData.run(socket.assigns.current_scope, summary.id) do
      {:ok, run} -> run
      _ -> summary
    end
  end

  defp refreshed(_socket, _log, summary), do: summary

  # Reads the missing events after the loaded bound until they reach the pushed ones.
  defp fill_gap(socket, log, pushed) do
    target = hd(pushed).seq
    missing = read_gap(socket.assigns.current_scope, log.id, log.max_seq, target, [])
    events = (missing ++ pushed) |> Enum.uniq_by(& &1.seq) |> Enum.sort_by(& &1.seq)
    insert(socket, log, Enum.reject(events, &(&1.seq <= log.max_seq)))
  end

  defp read_gap(scope, id, after_seq, target, acc) do
    case RunData.events(scope, id, after_seq: after_seq, limit: @gap_page) do
      {:ok, %{events: [_ | _] = events}} ->
        last = List.last(events).seq
        acc = acc ++ events
        if last >= target - 1, do: acc, else: read_gap(scope, id, last, target, acc)

      _ ->
        acc
    end
  end

  defp insert(socket, log, events) do
    {views, log} =
      Enum.map_reduce(events, log, fn event, log ->
        log = remember_tool(log, event)
        {view(event, log.tools), log}
      end)

    max_seq = Enum.reduce(events, log.max_seq, &max(&1.seq, &2))
    # Once earlier events were loaded on request, new ones do not push them out.
    cap = if log.cap > @window, do: log.cap + length(views), else: log.cap
    # The stream holds consecutive events up to `max_seq` and trims to `cap`: keep
    # `min_seq` (the 加载更早 cursor) on the earliest event still shown.
    min_seq = max(log.min_seq || 1, max_seq - cap + 1)
    log = %{log | max_seq: max_seq, cap: cap, min_seq: min_seq}

    socket
    |> Phoenix.Component.assign(:run_log, log)
    |> LiveView.stream(:run_events, views, limit: -log.cap)
  end

  defp remember_tool(log, %{type: "tool_call", data: %{"call_id" => id, "name" => name}})
       when is_binary(id) do
    order = Enum.take([id | List.delete(log.tool_order, id)], @max_tools)
    %{log | tools: Map.take(Map.put(log.tools, id, name), order), tool_order: order}
  end

  defp remember_tool(log, _event), do: log

  defp view(event, tools) do
    tool =
      case event do
        %{type: "tool_result", data: %{"call_id" => id}} -> tools[id]
        _ -> nil
      end

    %{seq: event.seq, type: event.type, data: event.data || %{}, at: event.at, tool: tool}
  end

  ## Rendering

  attr :log, :map, required: true
  attr :events, :any, required: true
  attr :scope, :map, required: true

  def log(assigns) do
    ~H"""
    <div id="run-log" class="flex min-h-0 flex-1 flex-col gap-3" data-run-log={@log.id}>
      <p
        :if={@log.state == :not_found}
        id="run-log-not-found"
        class="py-6 text-center text-body text-fg-muted"
      >
        {dgettext("ui", "运行不存在")}
      </p>
      <.head :if={@log.run} run={@log.run} scope={@scope} />
      <p :if={@log.state == :viewer} id="run-log-viewer" class="text-body text-fg-muted">
        {dgettext("ui", "需要成员权限查看执行记录")}
      </p>
      <p :if={@log.state == :pruned} id="run-log-pruned" class="text-body text-fg-muted">
        {dgettext("ui", "执行记录已在运行结束 30 天后清理")}
      </p>
      <p :if={@log.state == :unavailable} id="run-log-unavailable" class="text-body text-fg-muted">
        {dgettext("ui", "执行记录暂不可用")}
      </p>
      <div :if={@log.state == :events} class="relative flex min-h-0 flex-1 flex-col">
        <div class="flex justify-center">
          <.button
            :if={@log.min_seq > 1}
            id="run-log-earlier"
            size="xs"
            variant="ghost"
            phx-click="run_log_earlier"
          >
            {dgettext("ui", "加载更早的记录")}
          </.button>
        </div>
        <ol
          id="run-log-events"
          phx-update="stream"
          phx-hook=".RunLogScroll"
          class="min-h-0 flex-1 overflow-y-auto"
          data-jump="#run-log-jump"
        >
          <li :for={{dom_id, ev} <- @events} id={dom_id} class="py-1" data-type={ev.type}>
            <.event event={ev} scope={@scope} />
          </li>
        </ol>
        <button
          id="run-log-jump"
          type="button"
          hidden
          class="absolute right-3 bottom-3 inline-flex h-7 items-center gap-1 rounded-badge border border-border bg-raised px-2 text-caption text-fg shadow-popover"
        >
          <.icon name="lucide-arrow-down" class="size-3.5" />{dgettext("ui", "跳到最新")}
        </button>
      </div>
      <script :type={Phoenix.LiveView.ColocatedHook} name=".RunLogScroll">
        export default {
          mounted() {
            this.jump = document.querySelector(this.el.dataset.jump)
            this.stick = true
            this.el.addEventListener("scroll", () => {
              this.stick = this.el.scrollHeight - this.el.scrollTop - this.el.clientHeight < 32
              if (this.stick && this.jump) this.jump.hidden = true
            })
            if (this.jump) this.jump.addEventListener("click", () => this.bottom())
            this.bottom()
          },
          beforeUpdate() {
            this.prevHeight = this.el.scrollHeight
            this.prevTop = this.el.scrollTop
            this.firstId = this.el.firstElementChild && this.el.firstElementChild.id
          },
          updated() {
            const first = this.el.firstElementChild && this.el.firstElementChild.id
            if (first !== this.firstId && !this.stick) {
              // Earlier events were added on top: keep the viewport where it was.
              this.el.scrollTop = this.prevTop + (this.el.scrollHeight - this.prevHeight)
            } else if (this.stick) {
              this.bottom()
            } else if (this.jump) {
              this.jump.hidden = false
            }
          },
          bottom() {
            this.el.scrollTop = this.el.scrollHeight
            this.stick = true
            if (this.jump) this.jump.hidden = true
          }
        }
      </script>
    </div>
    """
  end

  attr :run, :map, required: true
  attr :scope, :map, required: true

  defp head(assigns) do
    ~H"""
    <div
      id="run-log-head"
      class="flex flex-col gap-1 rounded-box border border-border bg-surface px-3 py-2"
    >
      <div class="flex flex-wrap items-center gap-2 text-body">
        <.run_status_badge status={@run.status} />
        <span class="font-medium text-fg">{@run.agent}</span>
        <.task_id_link :if={@run.task} ident={@run.task} workspace={@scope.workspace.slug} />
        <span class="font-mono text-caption text-fg-subtle">#{@run.id}</span>
      </div>
      <div class="flex flex-wrap gap-x-3 text-caption text-fg-muted">
        <span>{trigger_summary(@run.triggers)}</span>
        <span :if={duration_text(@run)}>{duration_text(@run)}</span>
        <span :if={usage_text(@run[:usage])}>{usage_text(@run[:usage])}</span>
      </div>
      <p :if={@run.failure_reason} id="run-log-failure" class="text-caption text-danger-fg">
        {failure_label(@run.failure_reason)}<span :if={@run[:error]}>：{@run.error}</span>
      </p>
    </div>
    """
  end

  attr :event, :map, required: true
  attr :scope, :map, required: true

  defp event(%{event: %{type: "text"}} = assigns) do
    ~H"""
    <.markdown
      content={@event.data["text"] || ""}
      scope={@scope}
      anchor_ns={"ev-#{@event.seq}"}
    />
    """
  end

  defp event(%{event: %{type: "thinking"}} = assigns) do
    ~H"""
    <details class="text-body text-fg-muted">
      <summary class="cursor-pointer text-caption">{dgettext("ui", "思考")}</summary>
      <p class="whitespace-pre-wrap">{@event.data["text"]}</p>
    </details>
    """
  end

  defp event(%{event: %{type: "tool_call"}} = assigns) do
    ~H"""
    <details class="text-body">
      <summary class="cursor-pointer font-mono text-label text-fg" data-tool>
        {@event.data["name"]}
      </summary>
      <pre class="mt-1 overflow-x-auto rounded-field bg-raised p-2 font-mono text-label text-fg-muted">{@event.data["input"]}</pre>
    </details>
    """
  end

  defp event(%{event: %{type: "tool_result"}} = assigns) do
    ~H"""
    <details class={[
      "rounded-field border px-2 py-1 text-body",
      if(@event.data["is_error"], do: "border-danger", else: "border-border")
    ]}>
      <summary class="cursor-pointer text-caption text-fg-muted" data-tool-output>
        {if(@event.tool,
          do: dgettext("ui", "%{tool} 的输出", tool: @event.tool),
          else: dgettext("ui", "工具输出")
        )}
        <span :if={@event.data["is_error"]} class="text-danger-fg">{dgettext("ui", "（出错）")}</span>
        <span :if={@event.data["truncated"]}>{dgettext("ui", "（输出已截断）")}</span>
      </summary>
      <pre class="mt-1 overflow-x-auto font-mono text-label text-fg-muted">{@event.data["output"]}</pre>
    </details>
    """
  end

  defp event(%{event: %{type: "result"}} = assigns) do
    ~H"""
    <div class="rounded-box border border-brand px-3 py-2" data-result>
      <.markdown content={@event.data["text"] || ""} scope={@scope} anchor_ns={"ev-#{@event.seq}"} />
    </div>
    """
  end

  defp event(%{event: %{type: "error"}} = assigns) do
    ~H"""
    <p class="text-body text-danger-fg" data-error>
      <span class="font-medium">{failure_label(@event.data["reason"])}</span>
      <span :if={@event.data["message"]}>：{@event.data["message"]}</span>
    </p>
    """
  end

  defp event(%{event: %{type: "status"}} = assigns) do
    ~H"""
    <p
      class={[
        "text-caption",
        if(@event.data["level"] == "warning", do: "text-warning-fg", else: "text-info-fg")
      ]}
      data-level={@event.data["level"]}
    >
      {@event.data["message"]}
    </p>
    """
  end

  defp event(%{event: %{type: "session"}} = assigns) do
    ~H"""
    <p class="text-caption text-fg-subtle">
      {dgettext("ui", "会话 %{id}", id: @event.data["session_id"])}
    </p>
    """
  end

  defp event(%{event: %{type: "usage"}} = assigns) do
    ~H"""
    <p class="text-caption text-fg-subtle" data-usage>
      {dgettext("ui", "用量")} {usage_text(@event.data)}
    </p>
    """
  end

  defp event(assigns) do
    ~H"""
    <p class="text-caption text-fg-subtle">{@event.type}</p>
    """
  end
end
