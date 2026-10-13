defmodule HelmsmanWeb.TaskPicker do
  @moduledoc """
  Task picker (add-collaboration-ui D6): a search box over the workspace's tasks
  (`Helmsman.Search.search/3`) and at most #{8} results. Picking one, or clearing the
  pick, sends `{:task_picked, id, summary | nil}` to the LiveView.

  Assigns: `id`, `scope`, `label`, `project_key` (context project), `epic_only`
  (only epics; with an empty query it lists the context project's epics), `exclude`
  (task IDs never offered). The picker has its own form: Enter in the box picks the
  first result of the text submitted (an empty box picks nothing), Tab moves through
  the result buttons.
  """
  use HelmsmanWeb, :live_component

  alias Helmsman.{Search, Tasks}

  @shown 8
  @searched 50

  @impl true
  def mount(socket) do
    {:ok, assign(socket, q: "", results: [], selected: nil, error: nil, defaults: nil)}
  end

  @impl true
  def update(assigns, socket) do
    socket =
      socket
      |> assign(Map.take(assigns, [:id, :scope]))
      |> assign(
        label: assigns[:label],
        project_key: assigns[:project_key],
        epic_only: assigns[:epic_only] || false,
        exclude: MapSet.new(assigns[:exclude] || [])
      )

    socket =
      if socket.assigns.defaults == nil,
        do: assign(socket, :defaults, defaults(socket.assigns)),
        else: socket

    {:ok,
     if(socket.assigns.q == "",
       do: assign(socket, :results, shown(socket, :defaults)),
       else: socket
     )}
  end

  @impl true
  def handle_event("search", %{"q" => q}, socket) when is_binary(q),
    do: {:noreply, run_query(socket, q)}

  # Enter submits the box's current text, which may be newer than the last `search`
  # (a submit cancels the pending debounce): query it first, then pick only from its
  # results (code review 1 P2).
  def handle_event("pick_first", %{"q" => q}, socket) when is_binary(q) do
    socket = run_query(socket, q)

    case {String.trim(socket.assigns.q), socket.assigns.results} do
      {"", _} -> {:noreply, socket}
      {_, [first | _]} -> {:noreply, pick(socket, first)}
      {_, []} -> {:noreply, socket}
    end
  end

  def handle_event("pick", %{"task" => ident}, socket) do
    case Enum.find(socket.assigns.results, &(&1.id == ident)) do
      nil -> {:noreply, socket}
      summary -> {:noreply, pick(socket, summary)}
    end
  end

  def handle_event("clear", _params, socket) do
    send(self(), {:task_picked, socket.assigns.id, nil})
    {:noreply, assign(socket, selected: nil)}
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  defp run_query(socket, q) do
    q = String.slice(q, 0, 300)

    case String.trim(q) do
      "" -> assign(socket, q: "", results: shown(socket, :defaults), error: nil)
      _ -> search(assign(socket, :q, q))
    end
  end

  defp pick(socket, summary) do
    send(self(), {:task_picked, socket.assigns.id, summary})
    assign(socket, selected: summary, q: "", results: shown(socket, :defaults), error: nil)
  end

  defp search(socket) do
    %{scope: scope, q: q} = socket.assigns

    case Search.search(scope, q, limit: @searched) do
      {:ok, hits} ->
        assign(socket, results: hits |> Enum.map(& &1.task) |> keep(socket), error: nil)

      {:error, _} ->
        assign(socket, results: [], error: dgettext("ui", "搜索词无效"))
    end
  end

  defp shown(socket, :defaults), do: keep(socket.assigns.defaults || [], socket)

  defp keep(summaries, socket) do
    %{epic_only: epic_only, exclude: exclude} = socket.assigns

    summaries
    |> Enum.filter(&(not epic_only or &1.kind == "epic"))
    |> Enum.reject(&MapSet.member?(exclude, &1.id))
    |> Enum.take(@shown)
  end

  defp defaults(%{epic_only: true, project_key: key, scope: scope}) when is_binary(key) do
    case Tasks.list(scope, key, kind: :epic, limit: @searched) do
      {:ok, tasks} -> Enum.map(tasks, &Tasks.summary/1)
      {:error, _} -> []
    end
  end

  defp defaults(_assigns), do: []

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :slug, assigns.scope.workspace.slug)

    ~H"""
    <div id={@id} class="flex flex-col gap-1.5" data-task-picker>
      <div
        :if={@selected}
        id={"#{@id}-selected"}
        data-task={@selected.id}
        class="flex min-w-0 items-center gap-2 rounded-field border border-border bg-surface px-2 py-1.5"
      >
        <.status_icon status={@selected.status} />
        <span class="font-mono text-label text-fg-muted">{@selected.id}</span>
        <span class="min-w-0 flex-1 truncate text-body text-fg" title={@selected.title}>
          {@selected.title}
        </span>
        <button
          type="button"
          id={"#{@id}-clear"}
          phx-click="clear"
          phx-target={@myself}
          aria-label={dgettext("ui", "清除选择")}
          class="inline-flex size-6 items-center justify-center rounded-field text-fg-muted hover:bg-hover hover:text-fg"
        >
          <.icon name="lucide-x" class="size-3.5" />
        </button>
      </div>
      <.form
        :if={!@selected}
        for={%{}}
        id={"#{@id}-form"}
        phx-change="search"
        phx-submit="pick_first"
        phx-target={@myself}
      >
        <label :if={@label} for={"#{@id}-q"} class="mb-1 block text-label font-medium text-fg">
          {@label}
        </label>
        <div class="relative">
          <.icon
            name="lucide-search"
            class="pointer-events-none absolute left-2 top-1/2 size-3.5 -translate-y-1/2 text-fg-subtle"
          />
          <input
            id={"#{@id}-q"}
            name="q"
            type="search"
            value={@q}
            autocomplete="off"
            phx-debounce="300"
            aria-controls={"#{@id}-results"}
            placeholder={dgettext("ui", "输入任务 ID 或标题中的词")}
            class="block h-8 w-full rounded-field border border-border-strong bg-surface pl-7 pr-2 text-body text-fg focus:border-brand focus:outline-none"
          />
        </div>
      </.form>
      <p
        :if={!@selected && @error}
        id={"#{@id}-error"}
        role="alert"
        class="text-caption text-danger-fg"
      >
        {@error}
      </p>
      <ul
        :if={!@selected && @results != []}
        id={"#{@id}-results"}
        role="listbox"
        aria-label={dgettext("ui", "搜索结果")}
        class="flex flex-col rounded-box border border-border bg-raised p-1"
      >
        <li :for={task <- @results} role="option" aria-selected="false">
          <button
            type="button"
            id={"#{@id}-result-#{task.id}"}
            phx-click="pick"
            phx-value-task={task.id}
            phx-target={@myself}
            class="flex w-full min-w-0 items-center gap-2 rounded-field px-1.5 py-1 text-left hover:bg-hover focus-visible:bg-hover focus-visible:outline-none"
          >
            <.status_icon status={task.status} />
            <span class="font-mono text-label text-fg-muted">{task.id}</span>
            <span class="min-w-0 flex-1 truncate text-body text-fg">{task.title}</span>
            <HelmsmanWeb.CollabComponents.epic_badge kind={task.kind} />
          </button>
        </li>
      </ul>
      <p
        :if={!@selected && @results == [] && !@error && String.trim(@q) != ""}
        id={"#{@id}-none"}
        class="text-caption text-fg-subtle"
      >
        {dgettext("ui", "没有匹配的任务")}
      </p>
    </div>
    """
  end
end
