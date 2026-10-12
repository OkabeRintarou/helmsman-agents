defmodule HelmsmanWeb.TaskLive.Show do
  @moduledoc """
  Task page `/w/:slug/t/:ident` (designs D6–D9, specs web-tasks and
  web-task-transitions): title and description edited in place, property menus,
  transitions with their panels, and the history timeline.

  Every save carries the version the user started from; a stale save reloads the task
  and keeps the draft of the field being edited. Updates from `task:<id>` refresh the
  page without touching the fields being edited (they show 有更新 instead).
  """
  use HelmsmanWeb, :live_view

  alias Helmsman.{Events, Policy, Tasks}
  alias Helmsman.Tasks.StateMachine
  alias HelmsmanWeb.{FormErrors, TaskComponents, TaskData, TaskEvidence, TaskTransitions}
  alias HelmsmanWeb.TaskLive.TransitionErrors

  @fields ~w(title description)

  @impl true
  def mount(%{"ident" => ident}, _session, socket) do
    scope = socket.assigns.current_scope

    task =
      case Tasks.get(scope, ident) do
        {:ok, task} -> task
        {:error, :not_found} -> raise HelmsmanWeb.NotFoundError
      end

    detail = Tasks.detail(task)

    if connected?(socket) do
      Events.subscribe(Events.topic(:task, task.id))
    end

    {:ok,
     socket
     |> assign(
       task: detail,
       page_title: page_title(detail),
       can_edit?: Policy.authorize(scope, :update_task) == :ok,
       can_transition?: Policy.authorize(scope, :transition_task) == :ok,
       editing: %{"title" => nil, "description" => nil},
       field_errors: %{},
       labels_draft: nil,
       assignable: TaskData.assignable(scope),
       label_options: TaskData.labels(scope, detail.project_key),
       transition_panel: nil
     )
     |> then(
       &if(connected?(&1), do: push_event(&1, "hm:visit-task", %{ident: detail.id}), else: &1)
     )}
  end

  @impl true
  def handle_params(%{"ident" => ident}, uri, socket) do
    canonical = socket.assigns.task.id

    if ident != canonical do
      %URI{path: path, query: query} = URI.parse(uri)
      path = String.replace_suffix(path, "/t/#{ident}", "/t/#{canonical}")
      to = if query, do: "#{path}?#{query}", else: path
      {:noreply, push_navigate(socket, to: to, replace: true)}
    else
      {:noreply, socket}
    end
  end

  defp page_title(task), do: "#{task.id} #{task.title}"

  ## Title and description

  @impl true
  def handle_event("edit_field", %{"field" => field}, socket) when field in @fields do
    if socket.assigns.can_edit? do
      value = Map.fetch!(socket.assigns.task, String.to_existing_atom(field))

      editing =
        Map.put(socket.assigns.editing, field, %{
          draft: value,
          original: value,
          version: socket.assigns.task.lock_version,
          updated?: false
        })

      {:noreply,
       assign(socket,
         editing: editing,
         field_errors: Map.delete(socket.assigns.field_errors, field)
       )}
    else
      {:noreply, socket}
    end
  end

  def handle_event("draft_field", %{"field" => field, "value" => value}, socket)
      when field in @fields do
    {:noreply, update_editing(socket, field, &%{&1 | draft: value})}
  end

  def handle_event("save_field", %{"field" => field, "value" => value}, socket)
      when field in @fields do
    case socket.assigns.editing[field] do
      nil ->
        {:noreply, socket}

      edit ->
        socket = update_editing(socket, field, fn _ -> %{edit | draft: value} end)
        attrs = %{String.to_existing_atom(field) => value}
        {:noreply, save(socket, field, attrs, edit.version)}
    end
  end

  def handle_event("cancel_field", %{"field" => field}, socket) when field in @fields do
    {:noreply,
     assign(socket,
       editing: Map.put(socket.assigns.editing, field, nil),
       field_errors: Map.delete(socket.assigns.field_errors, field)
     )}
  end

  ## Priority, assignee and labels

  def handle_event("set_field", %{"field" => field, "value" => value} = params, socket)
      when field in ~w(priority assignee) do
    version = parse_version(params["version"]) || socket.assigns.task.lock_version
    {:noreply, save(socket, field, %{String.to_existing_atom(field) => value}, version)}
  end

  def handle_event("open_labels", _params, socket) do
    if socket.assigns.can_edit? do
      task = socket.assigns.task

      {:noreply,
       assign(socket, :labels_draft, %{selected: task.labels, version: task.lock_version})}
    else
      {:noreply, socket}
    end
  end

  def handle_event("toggle_label", %{"label" => label}, socket) do
    {:noreply,
     update_labels(socket, fn selected ->
       if label in selected, do: List.delete(selected, label), else: selected ++ [label]
     end)}
  end

  def handle_event("add_label", %{"new_label" => raw}, socket) do
    label = raw |> String.trim() |> String.downcase()

    {:noreply,
     update_labels(socket, fn selected ->
       if label == "" or label in selected, do: selected, else: selected ++ [label]
     end)}
  end

  def handle_event("save_labels", _params, socket) do
    case socket.assigns.labels_draft do
      nil ->
        {:noreply, socket}

      %{selected: selected, version: version} ->
        socket = assign(socket, :labels_draft, nil)

        if selected == socket.assigns.task.labels,
          do: {:noreply, socket},
          else: {:noreply, save(socket, "labels", %{labels: selected}, version)}
    end
  end

  ## Transitions

  # Buttons carry the status they were rendered for (`from`): "开始" and "打回" both
  # target in_progress, so a click made on an outdated page must not run whatever
  # transition the target means in the task's current status.
  def handle_event("transition", %{"to" => to} = params, socket) do
    from = params["from"]
    label = TaskTransitions.direct_label(to)

    case direct_button(from, to) do
      nil ->
        socket = refresh(socket)
        {:noreply, put_flash(socket, :error, stale_text(socket, label))}

      button ->
        case transition(socket, from, to, %{}) do
          {:ok, detail} ->
            {:noreply, put_task(socket, detail)}

          {:error, reason} ->
            {_where, text} = TransitionErrors.message(reason, button.label)
            {:noreply, socket |> refresh() |> put_flash(:error, text)}
        end
    end
  end

  def handle_event("open_transition", %{"to" => to} = params, socket) do
    from = socket.assigns.task.status
    found = Enum.find(buttons(socket.assigns), &(&1.to == to and &1.kind != :direct))

    case params["from"] == from && found do
      nil ->
        {:noreply, socket}

      false ->
        {:noreply, socket}

      button ->
        panel = %{
          to: button.to,
          from: socket.assigns.task.status,
          kind: button.kind,
          label: button.label,
          params: %{"result" => "none"},
          errors: %{},
          top: nil,
          blocked: nil
        }

        {:noreply, assign(socket, :transition_panel, panel)}
    end
  end

  def handle_event("close_transition", _params, socket),
    do: {:noreply, assign(socket, :transition_panel, nil)}

  def handle_event("transition_change", %{"transition" => params}, socket) do
    {:noreply, update_panel(socket, &%{&1 | params: params})}
  end

  def handle_event("submit_transition", %{"transition" => params}, socket) do
    panel = socket.assigns.transition_panel

    if panel == nil or panel.blocked do
      {:noreply, socket}
    else
      socket = update_panel(socket, &%{&1 | params: params})
      kind = if panel.kind == :reason, do: "reason", else: "evidence"

      case TaskEvidence.parse(Map.put(params, "kind", kind)) do
        {:error, errors} ->
          {:noreply, update_panel(socket, &%{&1 | errors: errors, top: nil})}

        {:ok, opts} ->
          {:noreply, run_transition(socket, panel, opts)}
      end
    end
  end

  defp direct_button(from, to) when is_binary(from) do
    Enum.find(
      TaskTransitions.buttons(from, [to]),
      &(&1.to == to and &1.kind == :direct)
    )
  end

  defp direct_button(_from, _to), do: nil

  defp stale_text(socket, label) do
    status = TaskComponents.status_label(socket.assigns.task.status)
    dgettext("ui", "任务状态已变为%{status}，无法%{action}", status: status, action: label)
  end

  # The domain layer compares `expected_from` with the task's status under its row
  # lock and answers `{:status_changed, current}` when they differ (design D12).
  defp transition(socket, from, to, opts) do
    %{current_scope: scope, task: task} = socket.assigns
    Tasks.transition(scope, task.id, to, Map.put(opts, :expected_from, from))
  end

  defp run_transition(socket, panel, opts) do
    case transition(socket, panel.from, panel.to, opts) do
      {:ok, detail} ->
        socket |> assign(:transition_panel, nil) |> put_task(detail)

      {:error, reason} ->
        case TransitionErrors.message(reason, panel.label) do
          {:blocked, text} ->
            socket |> refresh() |> update_panel(&%{&1 | blocked: text, errors: %{}, top: nil})

          {{:field, field}, text} ->
            update_panel(socket, &%{&1 | errors: %{field => text}, top: nil})

          {:top, text} ->
            update_panel(socket, &%{&1 | top: text, errors: %{}})
        end
    end
  end

  ## Notifications

  @impl true
  def handle_info({:task_updated, _ident}, socket), do: {:noreply, refresh(socket)}
  def handle_info({:task_transitioned, _payload}, socket), do: {:noreply, refresh(socket)}

  ## Helpers

  defp save(socket, field, attrs, version) do
    %{current_scope: scope, task: task} = socket.assigns

    case Tasks.update(scope, task.id, attrs, version) do
      {:ok, updated} ->
        socket
        |> put_task(Tasks.detail(updated))
        |> assign(
          editing: clear_editing(socket.assigns.editing, field),
          field_errors: Map.delete(socket.assigns.field_errors, field)
        )

      {:error, :stale} ->
        socket = refresh(socket)
        latest = socket.assigns.task.lock_version

        socket
        |> update_editing(field, &%{&1 | version: latest, updated?: false})
        |> put_flash(:error, dgettext("ui", "此任务已被其他人修改，已加载最新内容"))

      {:error, %Ecto.Changeset{} = changeset} ->
        messages = FormErrors.messages(changeset)
        text = messages |> Map.values() |> List.flatten() |> List.first()
        assign(socket, :field_errors, Map.put(socket.assigns.field_errors, field, text))

      {:error, :forbidden} ->
        put_flash(socket, :error, dgettext("ui", "没有权限执行此操作"))

      {:error, reason} ->
        require Logger
        Logger.error("Task update failed: #{inspect(reason)}")
        put_flash(socket, :error, dgettext("ui", "操作失败，请稍后重试"))
    end
  end

  defp clear_editing(editing, field) when field in @fields, do: Map.put(editing, field, nil)
  defp clear_editing(editing, _field), do: editing

  defp update_editing(socket, field, fun) when field in @fields do
    case socket.assigns.editing[field] do
      nil -> socket
      edit -> assign(socket, :editing, Map.put(socket.assigns.editing, field, fun.(edit)))
    end
  end

  defp update_editing(socket, _field, _fun), do: socket

  defp update_labels(socket, fun) do
    case socket.assigns.labels_draft do
      nil -> socket
      draft -> assign(socket, :labels_draft, %{draft | selected: fun.(draft.selected)})
    end
  end

  defp update_panel(socket, fun) do
    case socket.assigns.transition_panel do
      nil -> socket
      panel -> assign(socket, :transition_panel, fun.(panel))
    end
  end

  defp parse_version(nil), do: nil

  defp parse_version(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp parse_version(value) when is_integer(value), do: value

  defp refresh(socket) do
    case Tasks.get(socket.assigns.current_scope, socket.assigns.task.id) do
      {:ok, task} -> put_task(socket, Tasks.detail(task))
      {:error, _} -> socket
    end
  end

  # New task data: fields being edited keep their draft and are flagged when changed
  # by someone else; an open transition panel is blocked if its transition is gone.
  defp put_task(socket, detail) do
    editing =
      Map.new(socket.assigns.editing, fn
        {field, nil} ->
          {field, nil}

        {field, edit} ->
          changed? = Map.fetch!(detail, String.to_existing_atom(field)) != edit.original
          {field, %{edit | updated?: edit.updated? or changed?}}
      end)

    label_options = Enum.uniq(socket.assigns.label_options ++ detail.labels) |> Enum.sort()

    socket
    |> assign(
      task: detail,
      page_title: page_title(detail),
      editing: editing,
      label_options: label_options
    )
    |> check_panel()
  end

  defp check_panel(socket) do
    task = socket.assigns.task

    case socket.assigns.transition_panel do
      %{blocked: nil, to: to, from: from, label: label} = panel ->
        if task.status != from or to not in allowed(task.status) do
          {:blocked, text} =
            TransitionErrors.message({:invalid_transition, task.status, to, []}, label)

          assign(socket, :transition_panel, %{panel | blocked: text})
        else
          socket
        end

      _ ->
        socket
    end
  end

  defp allowed(status),
    do: status |> String.to_existing_atom() |> StateMachine.allowed() |> Enum.map(&to_string/1)

  defp buttons(%{can_transition?: false}), do: []

  defp buttons(%{task: task}),
    do: TaskTransitions.buttons(task.status, allowed(task.status))

  ## Rendering

  @impl true
  def render(assigns) do
    buttons = buttons(assigns)
    {primary, secondary} = Enum.split_with(buttons, & &1.primary?)
    slug = assigns.current_scope.workspace.slug

    assigns =
      assign(assigns,
        slug: slug,
        primary: primary,
        secondary: secondary,
        assignees: assignee_options(assigns.assignable, assigns.task.assignee)
      )

    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} shell={@shell}>
      <:header>
        <.page_header title={@task.id}>
          <:crumb navigate={"/w/#{@slug}/p/#{@task.project_key}"}>{@task.project_key}</:crumb>
          <:actions>
            <span id="task-status"><.status_badge status={@task.status} /></span>
            <div :if={@secondary != []} class="flex items-center gap-2 max-sm:hidden">
              <.transition_button :for={button <- @secondary} button={button} from={@task.status} />
            </div>
            <.dropdown
              :if={@secondary != []}
              id="transition-more"
              label={dgettext("ui", "更多")}
              align={:end}
              class="sm:hidden"
              trigger_class="h-8 w-8 justify-center"
              items={Enum.map(@secondary, &more_item(&1, @task.status))}
            >
              <:trigger><.icon name="lucide-ellipsis" class="size-4" /></:trigger>
            </.dropdown>
            <.transition_button :for={button <- @primary} button={button} from={@task.status} />
          </:actions>
        </.page_header>
      </:header>
      <div class="grid gap-6 px-4 py-4 lg:grid-cols-[minmax(0,1fr)_320px] lg:px-6" id="task-layout">
        <section class="flex min-w-0 flex-col gap-4" aria-label={dgettext("ui", "任务内容")}>
          <.title_field
            task={@task}
            edit={@editing["title"]}
            error={@field_errors["title"]}
            can_edit?={@can_edit?}
          />
          <.description_field
            task={@task}
            edit={@editing["description"]}
            error={@field_errors["description"]}
            can_edit?={@can_edit?}
          />
        </section>
        <aside class="flex min-w-0 flex-col gap-6" aria-label={dgettext("ui", "属性")}>
          <div id="task-properties">
            <.property_list>
              <.property_row label={dgettext("ui", "状态")}>
                <.status_badge status={@task.status} />
              </.property_row>
              <.property_row label={dgettext("ui", "优先级")} id="task-priority">
                <.dropdown
                  :if={@can_edit?}
                  id="priority-menu"
                  label={dgettext("ui", "优先级")}
                  items={priority_items(@task)}
                  trigger_class="h-7 px-1.5 -mx-1.5"
                >
                  <:trigger>
                    <.priority_icon priority={@task.priority} />
                    <span>{TaskComponents.priority_label(@task.priority)}</span>
                  </:trigger>
                </.dropdown>
                <span :if={!@can_edit?} class="inline-flex items-center gap-1.5">
                  <.priority_icon priority={@task.priority} />
                  {TaskComponents.priority_label(@task.priority)}
                </span>
                <.field_error error={@field_errors["priority"]} />
              </.property_row>
              <.property_row label={dgettext("ui", "标签")} id="task-labels">
                <.labels_field
                  task={@task}
                  draft={@labels_draft}
                  options={@label_options}
                  can_edit?={@can_edit?}
                />
                <.field_error error={@field_errors["labels"]} />
              </.property_row>
              <.property_row label={dgettext("ui", "执行方")} id="task-assignee">
                <.dropdown
                  :if={@can_edit?}
                  id="assignee-menu"
                  label={dgettext("ui", "执行方")}
                  items={assignee_items(@assignees, @task)}
                  trigger_class="h-7 px-1.5 -mx-1.5 min-w-0"
                >
                  <:trigger><TaskComponents.actor_ref actor={@task.assignee} /></:trigger>
                </.dropdown>
                <TaskComponents.actor_ref :if={!@can_edit?} actor={@task.assignee} />
                <.field_error error={@field_errors["assignee"]} />
              </.property_row>
              <.property_row label={dgettext("ui", "提出方")} id="task-creator">
                <TaskComponents.actor_ref actor={@task.created_by} />
              </.property_row>
              <.property_row label={dgettext("ui", "提交")} id="task-commits">
                <span :if={Map.get(@task, :commits, []) != []} class="flex flex-wrap gap-1">
                  <code
                    :for={hash <- Map.get(@task, :commits, [])}
                    class="font-mono text-label text-fg-muted"
                    title={hash}
                  >
                    {String.slice(hash, 0, 7)}
                  </code>
                </span>
                <span :if={Map.get(@task, :commits, []) == []} class="text-fg-subtle">—</span>
              </.property_row>
              <.property_row label={dgettext("ui", "创建")}>
                <.relative_time id="task-created-at" at={@task.created_at} />
              </.property_row>
              <.property_row label={dgettext("ui", "更新")}>
                <.relative_time
                  id={"task-updated-at-#{:erlang.phash2(@task.updated_at)}"}
                  at={@task.updated_at}
                />
              </.property_row>
            </.property_list>
          </div>
          <section aria-labelledby="task-history-title">
            <h2 id="task-history-title" class="mb-1 text-label font-medium text-fg-muted">
              {dgettext("ui", "历史")}
            </h2>
            <ol id="task-history" class="flex flex-col divide-y divide-border">
              <TaskComponents.history_entry
                :for={{entry, i} <- Enum.with_index(@task.history)}
                id={"history-#{i}"}
                entry={entry}
              />
            </ol>
          </section>
        </aside>
      </div>
      <.transition_panel
        panel={@transition_panel}
        task={@task}
        scope={@current_scope}
      />
    </Layouts.app>
    """
  end

  attr :button, :map, required: true
  attr :from, :string, required: true

  defp transition_button(assigns) do
    ~H"""
    <.button
      id={"transition-#{@button.to}"}
      size="sm"
      variant={if(@button.primary?, do: "primary", else: "secondary")}
      data-kind={@button.kind}
      phx-click={transition_click(@button, @from)}
    >
      {@button.label}
    </.button>
    """
  end

  defp transition_click(%{kind: :direct, to: to}, from),
    do: JS.push("transition", value: %{to: to, from: from})

  defp transition_click(%{to: to}, from),
    do: JS.push("open_transition", value: %{to: to, from: from})

  defp more_item(button, from) do
    %{
      id: "transition-more-#{button.to}",
      label: button.label,
      on_select: transition_click(button, from)
    }
  end

  attr :error, :string, default: nil

  defp field_error(assigns) do
    ~H"""
    <p :if={@error} role="alert" class="flex items-center gap-1 text-caption text-danger-fg">
      <.icon name="lucide-circle-alert" class="size-3.5" />{@error}
    </p>
    """
  end

  attr :task, :map, required: true
  attr :edit, :map, default: nil
  attr :error, :string, default: nil
  attr :can_edit?, :boolean, required: true

  defp title_field(%{edit: nil} = assigns) do
    ~H"""
    <h2 id="task-title" class="text-heading font-semibold text-fg">
      <button
        :if={@can_edit?}
        type="button"
        id="task-title-edit"
        class="-mx-1.5 w-full rounded-field px-1.5 text-left hover:bg-hover"
        phx-click={JS.push("edit_field", value: %{field: "title"})}
        aria-label={dgettext("ui", "编辑标题：%{title}", title: @task.title)}
      >
        {@task.title}
      </button>
      <span :if={!@can_edit?}>{@task.title}</span>
    </h2>
    """
  end

  defp title_field(assigns) do
    ~H"""
    <div id="task-title" class="flex flex-col gap-1">
      <label for="task-title-input" class="sr-only">{dgettext("ui", "标题")}</label>
      <input
        id="task-title-input"
        type="text"
        name="value"
        value={@edit.draft}
        phx-hook="Editor"
        data-field="title"
        data-submit="enter"
        autofocus
        autocomplete="off"
        aria-invalid={@error && "true"}
        aria-describedby={@error && "task-title-error"}
        class="h-9 w-full rounded-field border border-border-strong bg-surface px-2 text-heading font-semibold text-fg focus:border-brand focus:outline-none"
      />
      <p :if={@edit.updated?} class="text-caption text-warning-fg" data-updated>
        {dgettext("ui", "有更新")}
      </p>
      <p :if={@error} id="task-title-error" role="alert" class="text-caption text-danger-fg">
        {@error}
      </p>
    </div>
    """
  end

  defp description_field(%{edit: nil} = assigns) do
    ~H"""
    <div id="task-description" class="flex flex-col gap-2">
      <div class="flex items-center justify-between">
        <h3 class="text-label font-medium text-fg-muted">{dgettext("ui", "描述")}</h3>
        <.button
          :if={@can_edit? and @task.description != ""}
          id="task-description-edit"
          size="xs"
          variant="ghost"
          icon="lucide-pencil"
          phx-click={JS.push("edit_field", value: %{field: "description"})}
        >
          {dgettext("ui", "编辑")}
        </.button>
      </div>
      <p
        :if={@task.description != ""}
        id="task-description-text"
        class="whitespace-pre-wrap break-words text-body text-fg"
        phx-no-format
      >{@task.description}</p>
      <button
        :if={@task.description == "" and @can_edit?}
        type="button"
        id="task-description-placeholder"
        class="rounded-field px-1.5 py-1 -mx-1.5 text-left text-body text-fg-subtle hover:bg-hover"
        phx-click={JS.push("edit_field", value: %{field: "description"})}
      >
        {dgettext("ui", "添加描述…")}
      </button>
      <p :if={@task.description == "" and !@can_edit?} class="text-body text-fg-subtle">
        {dgettext("ui", "没有描述")}
      </p>
    </div>
    """
  end

  defp description_field(assigns) do
    ~H"""
    <div id="task-description" class="flex flex-col gap-2">
      <h3 class="text-label font-medium text-fg-muted">{dgettext("ui", "描述")}</h3>
      <form
        id="task-description-form"
        phx-change="draft_field"
        phx-submit="save_field"
        class="flex flex-col gap-2"
      >
        <input type="hidden" name="field" value="description" />
        <label for="task-description-input" class="sr-only">{dgettext("ui", "描述")}</label>
        <textarea
          id="task-description-input"
          name="value"
          rows="10"
          phx-hook="Editor"
          phx-debounce="300"
          data-field="description"
          data-submit="mod-enter"
          autofocus
          aria-invalid={@error && "true"}
          aria-describedby={@error && "task-description-error"}
          class="w-full rounded-field border border-border-strong bg-surface px-2 py-1.5 text-body leading-5 text-fg focus:border-brand focus:outline-none"
        >{@edit.draft}</textarea>
        <p :if={@error} id="task-description-error" role="alert" class="text-caption text-danger-fg">
          {@error}
        </p>
        <div class="flex items-center gap-2">
          <p :if={@edit.updated?} class="text-caption text-warning-fg" data-updated>
            {dgettext("ui", "有更新")}
          </p>
          <span class="ml-auto text-caption text-fg-subtle">
            <.kbd mod>Enter</.kbd>
            {dgettext("ui", "保存")}
          </span>
          <.button
            id="task-description-cancel"
            size="sm"
            phx-click={JS.push("cancel_field", value: %{field: "description"})}
          >
            {dgettext("ui", "取消")}
          </.button>
          <.button id="task-description-save" type="submit" size="sm" variant="primary">
            {dgettext("ui", "保存")}
          </.button>
        </div>
      </form>
    </div>
    """
  end

  attr :task, :map, required: true
  attr :draft, :map, default: nil
  attr :options, :list, required: true
  attr :can_edit?, :boolean, required: true

  defp labels_field(assigns) do
    ~H"""
    <div class="relative flex min-w-0 flex-wrap items-center gap-1">
      <button
        :if={@can_edit?}
        type="button"
        id="labels-trigger"
        aria-haspopup="true"
        aria-expanded={to_string(@draft != nil)}
        class="-mx-1.5 flex min-h-7 min-w-0 flex-wrap items-center gap-1 rounded-field px-1.5 hover:bg-hover"
        phx-click="open_labels"
      >
        <.task_labels labels={@task.labels} />
      </button>
      <span :if={!@can_edit?} class="flex flex-wrap items-center gap-1">
        <.task_labels labels={@task.labels} />
      </span>
      <div
        :if={@draft}
        id="labels-popover"
        data-hm-menu
        data-open
        data-cancel={JS.push("save_labels")}
        phx-click-away={JS.push("save_labels")}
        class="absolute top-full left-0 z-40 mt-1 flex w-60 flex-col gap-1 rounded-box border border-border bg-raised p-2 shadow-popover"
      >
        <form id="labels-new-form" phx-submit="add_label">
          <label for="labels-new" class="sr-only">{dgettext("ui", "新标签")}</label>
          <input
            id="labels-new"
            name="new_label"
            autofocus
            autocomplete="off"
            placeholder={dgettext("ui", "输入新标签后按 Enter")}
            class="h-7 w-full rounded-field border border-border-strong bg-surface px-2 text-label text-fg focus:border-brand focus:outline-none"
          />
        </form>
        <div
          role="group"
          aria-label={dgettext("ui", "标签")}
          class="flex max-h-60 flex-col overflow-y-auto"
        >
          <label
            :for={label <- Enum.uniq(@options ++ @draft.selected)}
            class="flex min-h-7 cursor-pointer items-center gap-2 rounded-field px-1.5 text-body hover:bg-hover"
          >
            <input
              type="checkbox"
              class="size-3.5 accent-brand"
              checked={label in @draft.selected}
              phx-click="toggle_label"
              phx-value-label={label}
              data-label={label}
            />
            {label}
          </label>
        </div>
        <.button size="xs" id="labels-done" phx-click="save_labels">{dgettext("ui", "完成")}</.button>
      </div>
    </div>
    """
  end

  attr :labels, :list, required: true

  defp task_labels(%{labels: []} = assigns) do
    ~H"""
    <span class="text-fg-subtle">—</span>
    """
  end

  defp task_labels(assigns) do
    ~H"""
    <span
      :for={label <- @labels}
      class="rounded-badge bg-hover px-1.5 text-caption text-fg-muted"
      data-label={label}
    >
      {label}
    </span>
    """
  end

  defp priority_items(task) do
    for {label, value} <- TaskComponents.priority_options() do
      %{
        id: "priority-#{value}",
        label: label,
        checked: task.priority == value,
        on_select: "set_field",
        value: %{field: "priority", value: value, version: task.lock_version}
      }
    end
  end

  defp assignee_options(assignable, current) do
    names = Enum.map(assignable, & &1.name)

    extra =
      if current && current.name not in names,
        do: [%{name: current.name, kind: current.kind}],
        else: []

    Enum.map(assignable, &%{name: &1.name, kind: to_string(&1.kind)}) ++ extra
  end

  # One-to-one with the name (`keel/dev`, `keel-dev` and `keel.dev` are all valid and
  # distinct), stable across menu filtering, and a valid HTML id.
  @doc false
  def assignee_item_id(name), do: "assignee-" <> Base.url_encode64(name, padding: false)

  defp assignee_items(options, task) do
    current = task.assignee && task.assignee.name

    [
      %{
        id: "assignee-none",
        label: dgettext("ui", "未指派"),
        icon: "lucide-circle-dashed",
        checked: current == nil,
        on_select: "set_field",
        value: %{field: "assignee", value: "", version: task.lock_version}
      }
      | Enum.map(options, fn actor ->
          %{
            id: assignee_item_id(actor.name),
            label: actor.name,
            icon: if(to_string(actor.kind) == "agent", do: "lucide-bot", else: "lucide-user"),
            checked: current == actor.name,
            on_select: "set_field",
            value: %{field: "assignee", value: actor.name, version: task.lock_version}
          }
        end)
    ]
  end

  defp passed_tests(%{last_done_tests: %{passed: true} = tests}), do: tests
  defp passed_tests(_hint), do: nil

  # Always rendered (closed when `panel` is nil) so that closing runs the overlay's
  # phx-remove and gives the page back its focus and pointer events.
  attr :panel, :map, default: nil
  attr :task, :map, required: true
  attr :scope, :map, required: true

  defp transition_panel(%{panel: nil} = assigns) do
    ~H"""
    <.side_panel id="transition-panel" show={false} title="" on_cancel={JS.push("close_transition")}>
      <div />
    </.side_panel>
    """
  end

  defp transition_panel(assigns) do
    panel = assigns.panel

    hint =
      panel.to == "verified" && TaskTransitions.self_verify_hint(assigns.task, assigns.scope)

    assigns =
      assign(assigns,
        hint: hint,
        result: panel.params["result"] || "none",
        help: panel.kind == :reason && TaskTransitions.panel_help(panel.from, panel.to)
      )

    ~H"""
    <.side_panel
      id="transition-panel"
      show
      title={"#{@panel.label} #{@task.id}"}
      dirty
      on_cancel={JS.push("close_transition")}
    >
      <:error :if={@panel.blocked || @panel.top}>
        <span id="transition-panel-error">{@panel.blocked || @panel.top}</span>
      </:error>
      <div
        :if={@hint}
        id="self-verify-hint"
        class="mb-4 rounded-field border border-border tint-info px-3 py-2 text-body text-info-fg"
      >
        <span :if={passed_tests(@hint)}>{dgettext("ui", "你是执行方：验收需要通过的测试结果。最近一次完成已附带通过的测试：")}<code class="font-mono">{passed_tests(
          @hint
        ).command}</code></span>
        <span :if={!passed_tests(@hint)}>{dgettext("ui", "你是执行方：验收需要通过的测试结果。最近一次完成没有附带通过的测试，请在下方填写")}</span>
      </div>
      <p :if={@help} id="transition-help" class="mb-4 text-body text-fg-muted">{@help}</p>
      <.form
        for={%{}}
        as={:transition}
        id="transition-form"
        phx-change="transition_change"
        phx-submit="submit_transition"
        class="flex flex-col gap-4"
      >
        <%= if @panel.kind == :evidence do %>
          <.input
            type="textarea"
            id="transition-commits"
            name="transition[commits]"
            label={dgettext("ui", "提交")}
            help={dgettext("ui", "每行一个提交 hash，也可以用空格或逗号分隔")}
            value={@panel.params["commits"]}
            errors={List.wrap(@panel.errors[:commits])}
            rows="3"
            class="font-mono"
          />
          <.input
            type="radio"
            id="transition-result"
            name="transition[result]"
            label={dgettext("ui", "测试结果")}
            value={@result}
            options={[
              {dgettext("ui", "不附测试结果"), "none"},
              {dgettext("ui", "通过"), "passed"},
              {dgettext("ui", "未通过"), "failed"}
            ]}
            errors={List.wrap(@panel.errors[:tests])}
          />
          <%= if @result in ~w(passed failed) do %>
            <.input
              id="transition-command"
              name="transition[command]"
              label={dgettext("ui", "测试命令")}
              value={@panel.params["command"]}
              errors={List.wrap(@panel.errors[:command])}
              class="font-mono"
              autocomplete="off"
            />
            <.input
              id="transition-summary"
              name="transition[summary]"
              label={dgettext("ui", "摘要（可选）")}
              value={@panel.params["summary"]}
              autocomplete="off"
            />
          <% end %>
          <.input
            type="textarea"
            id="transition-comment"
            name="transition[comment]"
            label={dgettext("ui", "备注（可选）")}
            value={@panel.params["comment"]}
            errors={List.wrap(@panel.errors[:comment])}
            rows="4"
          />
        <% else %>
          <.input
            type="textarea"
            id="transition-comment"
            name="transition[comment]"
            label={dgettext("ui", "原因")}
            value={@panel.params["comment"]}
            errors={List.wrap(@panel.errors[:comment])}
            rows="5"
          />
        <% end %>
      </.form>
      <:footer :let={cancel}>
        <span />
        <div class="flex items-center gap-2">
          <.button phx-click={cancel}>{dgettext("ui", "取消")}</.button>
          <.button
            id="transition-submit"
            type="submit"
            form="transition-form"
            variant="primary"
            disabled={@panel.blocked != nil}
          >
            {@panel.label}
          </.button>
        </div>
      </:footer>
    </.side_panel>
    """
  end
end
