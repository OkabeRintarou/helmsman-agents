defmodule HelmsmanWeb.TaskRuns do
  @moduledoc """
  The 运行 section of the task page (spec web-runs 任务详情页的运行区, design D8, D8a).

  * Open runs come from R9: `active` complete, and every pending run (the loop reads up
    to `pending_total`). The header marker and the 验收 lock depend on `active` only.
  * Finished runs come from R10: the newest 3 with the total; 显示全部 shows a stream
    window of 20 that 加载更多 grows by 20. Every refresh re-reads from the first page
    (`HelmsmanWeb.RunData.read_window/2`) and resets the stream.

  The page keeps the state in `socket.assigns.task_runs` and the stream `:task_runs`.
  """
  use HelmsmanWeb, :html

  import HelmsmanWeb.RunComponents, only: [run_card: 1, cancellable?: 2, retryable?: 2]

  alias HelmsmanWeb.{RunData, Url}

  @recent 3
  @page 20
  @first_pending 200

  @doc "Initial state; call `load/1` after."
  def init(socket) do
    socket
    |> Phoenix.Component.assign(:task_runs, %{
      active: [],
      pending: [],
      recent: [],
      total: 0,
      expanded?: false,
      shown: @recent
    })
    |> Phoenix.LiveView.stream_configure(:task_runs, dom_id: &"task-run-#{&1.id}")
    |> Phoenix.LiveView.stream(:task_runs, [])
  end

  @doc "Reads the runs of the page's task (`socket.assigns.task.id` is the ident)."
  def load(socket) do
    %{current_scope: scope, task: task, task_runs: state} = socket.assigns
    target = {:task, task.id}

    with {:ok, open} <- open_all(scope, target),
         {:ok, finished} <- RunData.finished_window(scope, target, state.shown) do
      state = %{
        state
        | active: open.active,
          pending: open.pending,
          recent: Enum.take(finished.runs, @recent),
          total: finished.total
      }

      socket = Phoenix.Component.assign(socket, :task_runs, state)

      if state.expanded?,
        do: Phoenix.LiveView.stream(socket, :task_runs, finished.runs, reset: true),
        else: Phoenix.LiveView.stream(socket, :task_runs, [], reset: true)
    else
      {:error, _} -> socket
    end
  end

  # Every pending run of the task (design D8): one read when they fit, otherwise a
  # window of `pending_total`.
  defp open_all(scope, target) do
    with {:ok, open} <- RunData.open_window(scope, target, @first_pending) do
      if length(open.pending) < open.pending_total,
        do: RunData.open_window(scope, target, open.pending_total),
        else: {:ok, open}
    end
  end

  @doc "Handles `runs_show_all`, `runs_more` and `runs_collapse`."
  def handle_event("runs_show_all", socket), do: set_window(socket, true, @page)

  def handle_event("runs_more", socket),
    do: set_window(socket, true, socket.assigns.task_runs.shown + @page)

  def handle_event("runs_collapse", socket), do: set_window(socket, false, @recent)

  defp set_window(socket, expanded?, shown) do
    state = %{socket.assigns.task_runs | expanded?: expanded?, shown: shown}
    socket |> Phoenix.Component.assign(:task_runs, state) |> load()
  end

  @doc "Names of the agents with an active run, first claimed first, unique."
  def working_agents(%{active: active}), do: active |> Enum.map(& &1.agent) |> Enum.uniq()

  ## Rendering

  attr :state, :map, required: true
  attr :stream, :any, required: true
  attr :scope, :map, required: true
  attr :uri, :string, required: true
  attr :managed_assignee?, :boolean, default: false

  def section(assigns) do
    state = assigns.state

    assigns =
      assign(assigns,
        open: state.active ++ state.pending,
        empty?: state.active == [] and state.pending == [] and state.total == 0,
        more?: state.expanded? and state.shown < state.total
      )

    ~H"""
    <section id="task-runs" aria-labelledby="task-runs-title">
      <h2 id="task-runs-title" class="mb-2 text-label font-medium text-fg-muted">
        {dgettext("ui", "运行")}
      </h2>
      <div :if={@empty?} id="task-runs-empty" class="text-body text-fg-muted">
        <p>{dgettext("ui", "还没有运行")}</p>
        <p :if={@managed_assignee?} class="text-caption">{dgettext("ui", "指派后会自动开始运行")}</p>
      </div>
      <div :if={@open != []} id="task-runs-open" class="flex flex-col gap-2">
        <.run_card
          :for={run <- @open}
          id={"run-card-#{run.id}"}
          run={run}
          scope={@scope}
          log={Url.put_params(@uri, %{run: run.id})}
          can_cancel={cancellable?(@scope, run)}
          can_retry={false}
        />
      </div>
      <div :if={@state.total > 0} class="mt-2 flex flex-col gap-2">
        <div :if={!@state.expanded?} id="task-runs-recent" class="flex flex-col gap-2">
          <.run_card
            :for={run <- @state.recent}
            id={"run-card-#{run.id}"}
            run={run}
            scope={@scope}
            log={Url.put_params(@uri, %{run: run.id})}
            can_retry={retryable?(@scope, run)}
          />
        </div>
        <div
          :if={@state.expanded?}
          id="task-runs-history"
          phx-update="stream"
          class="flex flex-col gap-2"
        >
          <.run_card
            :for={{dom_id, run} <- @stream}
            id={dom_id}
            run={run}
            scope={@scope}
            log={Url.put_params(@uri, %{run: run.id})}
            can_retry={retryable?(@scope, run)}
          />
        </div>
        <.button
          :if={!@state.expanded? and @state.total > length(@state.recent)}
          id="task-runs-show-all"
          size="sm"
          variant="ghost"
          phx-click="runs_show_all"
        >
          {dgettext("ui", "显示全部（%{n}）", n: @state.total)}
        </.button>
        <.button :if={@more?} id="task-runs-more" size="sm" variant="ghost" phx-click="runs_more">
          {dgettext("ui", "加载更多")}
        </.button>
        <.button
          :if={@state.expanded?}
          id="task-runs-collapse"
          size="sm"
          variant="ghost"
          phx-click="runs_collapse"
        >
          {dgettext("ui", "收起")}
        </.button>
      </div>
    </section>
    """
  end
end
