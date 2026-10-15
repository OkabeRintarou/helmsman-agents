defmodule HelmsmanWeb.TaskLive.BoardComponents do
  @moduledoc "Accessible project board columns and cards."
  use HelmsmanWeb, :html
  alias Helmsman.Tasks.StateMachine
  alias HelmsmanWeb.{CollabComponents, TaskComponents, TaskTransitions}
  alias HelmsmanWeb.TaskLive.{Board, Filter}

  attr :streams, :map, required: true
  attr :columns, :list, required: true
  attr :counts, :map, required: true
  attr :pages, :map, required: true
  attr :filters, :map, required: true
  attr :hidden, :list, required: true
  attr :can_move, :boolean, required: true
  attr :can_create, :boolean, required: true
  attr :new_path, :string, required: true
  attr :slug, :string, required: true
  attr :agents, :map, required: true
  attr :appearance, :map, required: true
  attr :announcement, :string, required: true

  def board(assigns) do
    assigns =
      assign(assigns,
        transitions:
          Map.new(
            Filter.statuses(),
            &{&1,
             Enum.map(StateMachine.allowed(String.to_existing_atom(&1)), fn v -> to_string(v) end)}
          )
      )

    ~H"""
    <div id="task-board-wrapper" class="min-w-0 max-w-full px-4 pb-4">
      <p id="board-announcement" role="status" aria-live="polite" aria-atomic="true" class="sr-only">
        {@announcement}
      </p>
      <nav aria-label={dgettext("ui", "状态")} class="flex gap-2 overflow-x-auto pb-2 sm:hidden">
        <a
          :for={status <- @columns}
          href={"#board-column-#{status}"}
          data-board-anchor={status}
          class="inline-flex h-8 shrink-0 items-center gap-1 rounded-field bg-hover px-2 text-label"
        >
          {column_label(status)} <span>{@counts[status] || 0}</span>
        </a>
      </nav>
      <div
        id="task-board"
        phx-hook="BoardDrag"
        data-transitions={Jason.encode!(@transitions)}
        class="flex min-w-0 max-w-full gap-3 overflow-x-auto snap-x snap-mandatory pb-3"
      >
        <section
          :for={status <- @columns}
          id={"board-column-#{status}"}
          data-board-column={status}
          aria-dropeffect="none"
          aria-labelledby={"board-heading-#{status}"}
          class="w-[85vw] max-w-80 shrink-0 snap-start rounded-box border border-border bg-sunken sm:w-60"
        >
          <header class="flex items-center gap-2 px-3 py-2">
            <.status_icon status={status} />
            <h2 id={"board-heading-#{status}"} tabindex="-1" class="flex-1 text-label font-medium">
              {column_label(status)}
              <span data-board-count={status} class="text-fg-muted">{@counts[status] || 0}</span>
            </h2>
            <.button
              :if={status == "new" and @can_create}
              id="board-new-task"
              size="sm"
              icon="lucide-plus"
              patch={@new_path}
              aria-label={dgettext("ui", "新建任务")}
            ><span class="sr-only">{dgettext("ui", "新建任务")}</span></.button>
            <.dropdown
              :if={is_nil(@filters[:status]) and length(@columns) > 1}
              id={"board-hide-#{status}"}
              label={dgettext("ui", "隐藏此列")}
              align={:end}
              trigger_class="h-8 w-8 justify-center"
              items={[
                %{label: dgettext("ui", "隐藏此列"), on_select: "hide_column", value: %{status: status}}
              ]}
            >
              <:trigger><.icon name="lucide-ellipsis" class="size-4" /></:trigger>
            </.dropdown>
          </header>
          <div
            id={"board-cards-#{status}"}
            phx-update="stream"
            class="flex min-h-24 flex-col gap-2 px-2 pb-2"
          >
            <p
              id={"board-empty-#{status}"}
              class="hidden py-8 text-center text-caption text-fg-muted only:block"
            >
              {dgettext("ui", "还没有任务")}
            </p>
            <.card
              :for={{dom_id, task} <- @streams[Board.stream_name(status)]}
              dom_id={dom_id}
              task={task}
              can_move={@can_move}
              slug={@slug}
              agents={@agents}
              appearance={@appearance}
            />
          </div>
          <.button
            :if={@pages[status] && @pages[status].more}
            id={"board-more-#{status}"}
            phx-click="board_more"
            phx-value-status={status}
            class="m-2"
            size="sm"
          >{dgettext("ui", "加载更多")}</.button>
        </section>
        <div :if={is_nil(@filters[:status]) and @hidden != []} class="shrink-0">
          <.dropdown
            id="board-hidden"
            label={dgettext("ui", "已隐藏 %{n} 列", n: length(@hidden))}
            items={
              Enum.map(@hidden, fn s ->
                %{
                  id: "board-show-#{s}",
                  label: "#{column_label(s)} (#{@counts[s] || 0}) · #{dgettext("ui", "显示")}",
                  on_select: "show_column",
                  value: %{status: s}
                }
              end)
            }
          >
            <:trigger>{dgettext("ui", "已隐藏 %{n} 列", n: length(@hidden))}</:trigger>
          </.dropdown>
        </div>
      </div>
    </div>
    """
  end

  attr :dom_id, :string, required: true
  attr :task, :map, required: true
  attr :can_move, :boolean, required: true
  attr :slug, :string, required: true
  attr :agents, :map, required: true
  attr :appearance, :map, required: true

  def card(assigns) do
    assigns = assign(assigns, moves: moves(assigns.task))

    ~H"""
    <article
      id={@dom_id}
      data-task-id={@task.id}
      data-status={@task.status}
      data-blocked={to_string(@task.blocked || false)}
      data-can-move={@can_move && "true"}
      class={[
        "relative rounded-field border border-border bg-raised p-3 shadow-sm",
        @task[:highlight] && "motion-safe:animate-[pulse_1s_ease-in-out_2]"
      ]}
    >
      <.link
        id={"#{@dom_id}-link"}
        navigate={"/w/#{@slug}/t/#{@task.id}"}
        aria-label={"#{@task.id} #{@task.title}"}
        draggable="false"
        class="absolute inset-0 rounded-field focus-visible:ring-2 focus-visible:ring-brand"
      ><span class="sr-only">{@task.id} {@task.title}</span></.link>
      <div class="pointer-events-none flex items-center gap-2 text-caption text-fg-muted">
        <.priority_icon priority={@task.priority} /><span class="font-mono">{@task.id}</span>
        <CollabComponents.epic_badge :if={@task.kind == "epic"} kind="epic" />
        <.icon
          :if={@task.open_question}
          name="lucide-circle-question-mark"
          class="size-4 text-warning"
          label={dgettext("ui", "待回答")}
          data-open-question
        />
        <span class="flex-1" />
        <span :if={@task.assignee}><TaskComponents.actor_ref
          actor={@task.assignee}
          agents={@agents}
          appearance={@appearance}
          slug={@slug}
          compact
        /></span>
      </div>
      <p class="pointer-events-none mt-2 line-clamp-2 text-body font-medium text-fg">{@task.title}</p>
      <div class="pointer-events-none mt-2 flex flex-wrap gap-1">
        <span
          :for={{label, i} <- Enum.with_index(Enum.take(@task.labels, 3))}
          class={[
            "rounded-badge bg-hover px-1.5 text-caption text-fg-muted",
            i == 2 && "hidden sm:inline"
          ]}
        >{label}</span>
        <span :if={length(@task.labels) > 3} class="hidden text-caption text-fg-muted sm:inline">+{length(
          @task.labels
        ) - 3}</span>
        <span :if={length(@task.labels) > 2} class="text-caption text-fg-muted sm:hidden">+{length(
          @task.labels
        ) - 2}</span>
      </div>
      <CollabComponents.epic_progress
        :if={@task.kind == "epic"}
        progress={@task.progress}
        class="pointer-events-none mt-2"
        data-epic-progress
      />
      <p
        :if={@task.blocked}
        data-blocked
        class="pointer-events-none mt-2 text-caption text-warning-fg"
      >
        {dgettext("ui", "被阻塞")}
      </p>
      <p
        :if={@task[:run_state]}
        data-run-state={@task.run_state.status}
        class="pointer-events-none mt-2 text-caption text-fg-muted"
      >
        {run_label(@task.run_state)}
      </p>
      <div :if={@can_move} class="relative mt-2 flex justify-end">
        <.dropdown
          id={"board-move-#{@task.id}"}
          label={dgettext("ui", "移动 %{id}", id: @task.id)}
          items={@moves}
          align={:end}
          trigger_class="h-8 px-2 text-caption"
        >
          <:trigger><.icon name="lucide-arrow-right-left" class="size-3.5" /></:trigger>
        </.dropdown>
      </div>
    </article>
    """
  end

  def column_label("done"), do: dgettext("ui", "已完成")
  def column_label(status), do: TaskComponents.status_label(status)

  defp moves(task) do
    task.status
    |> TaskTransitions.buttons(StateMachine.allowed(String.to_existing_atom(task.status)))
    |> Enum.reject(&(&1.to == "in_progress" and task.status == "new" and task.blocked))
    |> Enum.map(fn button ->
      %{
        id: "board-move-#{task.id}-#{button.to}",
        label:
          dgettext("ui", "%{button} → %{column}",
            button: button.label,
            column: column_label(button.to)
          ),
        on_select: "move",
        value: %{id: task.id, from: task.status, to: button.to}
      }
    end)
  end

  defp run_label(%{status: :running, agents: [name]}),
    do: dgettext("ui", "%{name} 正在处理", name: name)

  defp run_label(%{status: :running, agents: [name | rest]}),
    do: dgettext("ui", "%{name} 等 %{count} 个正在处理", name: name, count: length(rest) + 1)

  defp run_label(%{status: :queued}), do: dgettext("ui", "排队中")
  defp run_label(%{status: :deferred}), do: dgettext("ui", "等前置任务")
  defp run_label(%{status: :failed}), do: dgettext("ui", "上次运行失败")
end
