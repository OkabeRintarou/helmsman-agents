defmodule HelmsmanWeb.TaskLive.Index do
  @moduledoc """
  A project's task list `/w/:slug/p/:key` (design D5, spec web-tasks): filter bar
  synced to the URL, a stream-backed table paged by 加载更多, live updates from
  `project:<id>`, and the project menu (edit, archive, restore; admins).

  Live updates never reload the table: a summary that passes the current filters is
  moved to the top, one that does not is removed (`HelmsmanWeb.TaskLive.Filter`).
  """
  use HelmsmanWeb, :live_view

  alias Helmsman.{Events, Policy, Projects, Tasks}
  alias HelmsmanWeb.{Filters, FormErrors, TaskComponents, TaskData, Url}
  alias HelmsmanWeb.TaskLive.Filter

  @impl true
  def mount(%{"key" => key}, _session, socket) do
    scope = socket.assigns.current_scope

    project =
      case Projects.get(scope, key) do
        {:ok, project} -> project
        {:error, :not_found} -> raise HelmsmanWeb.NotFoundError
      end

    if connected?(socket), do: Events.subscribe(Events.topic(:project, project.id))

    {:ok,
     socket
     |> stream_configure(:tasks, dom_id: &"task-#{&1.id}")
     |> assign(
       project: project,
       page_title: project.name,
       filters: nil,
       label_options: TaskData.labels(scope, project.key),
       assignable: TaskData.assignable(scope),
       can_manage?: Policy.authorize(scope, :update_project) == :ok,
       shown: MapSet.new(),
       cursor: nil,
       has_more: false,
       panel: nil,
       edit: nil
     )}
  end

  @impl true
  def handle_params(%{"key" => key} = params, uri, socket) do
    project = socket.assigns.project

    if key != project.key do
      {:noreply, push_navigate(socket, to: canonical(uri, key, project.key), replace: true)}
    else
      filters = Filters.parse(params, Filter.schema())
      socket = if filters != socket.assigns.filters, do: load(socket, filters), else: socket
      {:noreply, socket |> assign(:uri, relative(uri)) |> put_panel(params["panel"])}
    end
  end

  defp canonical(uri, key, canonical_key) do
    %URI{path: path, query: query} = URI.parse(uri)
    path = String.replace_suffix(path, "/p/#{key}", "/p/#{canonical_key}")
    if query, do: "#{path}?#{query}", else: path
  end

  defp relative(uri) do
    %URI{path: path, query: query} = URI.parse(uri)
    if query, do: "#{path}?#{query}", else: path
  end

  defp put_panel(socket, "edit-project") do
    %{project: project, can_manage?: can?} = socket.assigns

    cond do
      not can? ->
        assign(socket, panel: nil, edit: nil)

      socket.assigns.panel == "edit-project" ->
        socket

      true ->
        assign(socket,
          panel: "edit-project",
          edit: %{
            params: %{"name" => project.name, "description" => project.description || ""},
            errors: %{}
          }
        )
    end
  end

  defp put_panel(socket, _panel), do: assign(socket, panel: nil, edit: nil)

  defp load(socket, filters) do
    %{current_scope: scope, project: project} = socket.assigns
    opts = Filter.domain_opts(filters)
    {:ok, rows, has_more, cursor} = TaskData.page(scope, project.key, opts, nil)
    summaries = Enum.map(rows, &Tasks.summary/1)

    socket
    |> assign(
      filters: filters,
      has_more: has_more,
      cursor: cursor,
      shown: MapSet.new(summaries, & &1.id)
    )
    |> merge_labels(summaries)
    |> stream(:tasks, summaries, reset: true)
  end

  @impl true
  def handle_event("load_more", _params, socket), do: {:noreply, load_next(socket)}

  def handle_event("edit_project_change", %{"project" => params}, socket) do
    edit = %{socket.assigns.edit | params: Map.take(params, ~w(name description))}
    {:noreply, assign(socket, :edit, edit)}
  end

  def handle_event("edit_project_save", %{"project" => params}, socket) do
    %{current_scope: scope, project: project} = socket.assigns
    params = Map.take(params, ~w(name description))

    case Projects.update(scope, project.key, params) do
      {:ok, project} ->
        {:noreply,
         socket
         |> assign(project: project, page_title: project.name)
         |> push_patch(to: Url.drop_params(socket.assigns.uri, ["panel"]))}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         assign(socket, :edit, %{params: params, errors: FormErrors.messages(changeset)})}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, failure(reason))}
    end
  end

  def handle_event("archive", _params, socket),
    do: set_archived(socket, &Projects.archive/2, dgettext("ui", "项目已归档"))

  def handle_event("unarchive", _params, socket),
    do: set_archived(socket, &Projects.unarchive/2, dgettext("ui", "项目已恢复"))

  defp load_next(socket) do
    %{current_scope: scope, project: project, filters: filters} = socket.assigns
    opts = Filter.domain_opts(filters)

    {:ok, rows, has_more, cursor} = TaskData.page(scope, project.key, opts, socket.assigns.cursor)

    summaries = Enum.map(rows, &Tasks.summary/1)

    socket =
      Enum.reduce(summaries, socket, fn summary, socket ->
        stream_insert(socket, :tasks, summary, at: -1)
      end)

    socket
    |> assign(
      has_more: has_more,
      cursor: cursor,
      shown: Enum.reduce(summaries, socket.assigns.shown, &MapSet.put(&2, &1.id))
    )
    |> merge_labels(summaries)
  end

  defp set_archived(socket, fun, message) do
    case fun.(socket.assigns.current_scope, socket.assigns.project.key) do
      {:ok, project} ->
        {:noreply, socket |> assign(:project, project) |> put_flash(:info, message)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, failure(reason))}
    end
  end

  defp failure(:forbidden), do: dgettext("ui", "没有权限执行此操作")
  defp failure(_reason), do: dgettext("ui", "操作失败，请稍后重试")

  @impl true
  def handle_info({event, %{project_key: _} = summary}, socket)
      when event in [:task_created, :task_updated] do
    socket = merge_labels(socket, [summary])

    if Filter.match?(summary, socket.assigns.filters) do
      {:noreply,
       socket
       |> stream_delete(:tasks, summary)
       |> stream_insert(:tasks, summary, at: 0)
       |> assign(:shown, MapSet.put(socket.assigns.shown, summary.id))}
    else
      socket =
        socket
        |> stream_delete(:tasks, summary)
        |> assign(:shown, MapSet.delete(socket.assigns.shown, summary.id))

      {:noreply, refill(socket)}
    end
  end

  def handle_info({:projects_changed}, socket) do
    case Projects.get(socket.assigns.current_scope, socket.assigns.project.key) do
      {:ok, project} -> {:noreply, assign(socket, project: project, page_title: project.name)}
      {:error, _} -> {:noreply, socket}
    end
  end

  # Every loaded row left the filter but more may match after the cursor: load the
  # next page instead of reporting an empty list.
  defp refill(%{assigns: %{has_more: true}} = socket) do
    if MapSet.size(socket.assigns.shown) == 0, do: load_next(socket), else: socket
  end

  defp refill(socket), do: socket

  defp merge_labels(socket, summaries) do
    labels =
      summaries
      |> Enum.flat_map(&(&1.labels || []))
      |> Enum.concat(socket.assigns.label_options)
      |> Enum.uniq()
      |> Enum.sort()

    assign(socket, :label_options, labels)
  end

  @impl true
  def render(assigns) do
    slug = assigns.current_scope.workspace.slug
    base = "/w/#{slug}/p/#{assigns.project.key}"

    assigns =
      assign(assigns,
        slug: slug,
        base: base,
        archived?: assigns.project.archived_at != nil,
        dimensions: dimensions(assigns),
        view: Filter.current_view(assigns.filters),
        new_task_path: Url.put_params(assigns.uri, %{panel: "new"}),
        close_path: Url.drop_params(assigns.uri, ["panel"]),
        empty?: MapSet.size(assigns.shown) == 0 and not assigns.has_more
      )

    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} shell={@shell}>
      <:header>
        <.page_header title={@project.name}>
          <:crumb navigate={"/w/#{@slug}/projects"}>{dgettext("ui", "项目")}</:crumb>
          <:actions>
            <.dropdown
              :if={@can_manage?}
              id="project-menu"
              label={dgettext("ui", "项目菜单")}
              align={:end}
              items={project_menu(@archived?, @uri)}
              trigger_class="h-8 w-8 justify-center"
            >
              <:trigger><.icon name="lucide-ellipsis" class="size-4" /></:trigger>
            </.dropdown>
            <.button
              :if={@shell.can_create_task?}
              id="project-new-task"
              variant="primary"
              size="sm"
              icon="lucide-plus"
              patch={@new_task_path}
              disabled_reason={if(@archived?, do: dgettext("ui", "项目已归档"))}
            >
              {dgettext("ui", "新建任务")}
            </.button>
          </:actions>
        </.page_header>
      </:header>
      <div
        :if={@archived?}
        id="project-archived-banner"
        role="status"
        class="mx-4 mt-3 flex items-center gap-2 rounded-field border border-border tint-warning px-3 py-2 text-body text-warning-fg"
      >
        <.icon name="lucide-archive" class="size-4" />{dgettext("ui", "此项目已归档")}
      </div>
      <.filter_bar
        id="task-filters"
        path={@base}
        filters={@filters}
        dimensions={@dimensions}
        search={false}
      >
        <:views>
          <.link
            :for={{id, label, statuses} <- Filter.views()}
            id={"task-view-#{id}"}
            patch={Filters.path(@base, Filter.apply_view(@filters, statuses))}
            aria-current={@view == id && "page"}
            class={[
              "inline-flex h-7 items-center rounded-field px-2 text-label",
              if(@view == id,
                do: "bg-selected font-medium text-fg",
                else: "text-fg-muted hover:bg-hover hover:text-fg"
              )
            ]}
          >
            {label}
          </.link>
        </:views>
      </.filter_bar>
      <.data_table
        id="tasks"
        class={@empty? && "hidden"}
        rows={@streams.tasks}
        label={dgettext("ui", "%{project} 的任务", project: @project.name)}
        row_click={&JS.navigate("/w/#{@slug}/t/#{&1.id}")}
        row_version={& &1.updated_at}
        has_more={@has_more}
        load_more="load_more"
      >
        <:col :let={task} label={dgettext("ui", "状态")} class="w-10">
          <.status_icon status={task.status} />
        </:col>
        <:col :let={task} label="ID" class="w-24">
          <.task_id_link ident={task.id} workspace={@slug} status={task.status} />
        </:col>
        <:col :let={task} label={dgettext("ui", "标题")}>
          <span class="inline-flex min-w-0 items-center gap-1.5">
            <span class="truncate text-fg">{task.title}</span>
            <.tooltip :if={task.open_question} text={dgettext("ui", "待回答")} class="flex-none">
              <.icon
                name="lucide-circle-question-mark"
                class="size-3.5 text-warning"
                label={dgettext("ui", "待回答")}
                data-open-question
              />
            </.tooltip>
          </span>
        </:col>
        <:col :let={task} label={dgettext("ui", "标签")} secondary class="w-48">
          <span class="flex items-center gap-1 overflow-hidden">
            <button
              :for={label <- task.labels}
              type="button"
              data-label={label}
              class="rounded-badge bg-hover px-1.5 text-caption text-fg-muted hover:text-fg"
              phx-click={JS.patch(Filters.path(@base, Filters.put_single(@filters, :label, label)))}
            >
              {label}
            </button>
          </span>
        </:col>
        <:col :let={task} label={dgettext("ui", "优先级")} secondary class="w-16">
          <.priority_icon priority={task.priority} />
        </:col>
        <:col :let={task} label={dgettext("ui", "执行方")} class="w-32">
          <span :if={task.assignee}>
            <TaskComponents.actor_ref actor={task.assignee} compact />
          </span>
        </:col>
        <:col :let={task} label={dgettext("ui", "更新")} secondary class="w-24">
          <.relative_time
            id={"task-#{task.id}-updated-#{:erlang.phash2(task.updated_at)}"}
            at={task.updated_at}
            class="text-caption text-fg-muted"
          />
        </:col>
      </.data_table>
      <.empty_state
        :if={@empty? and @filters != %{}}
        kind={:filtered}
        on_clear={JS.patch(@base)}
      />
      <.empty_state
        :if={@empty? and @filters == %{}}
        icon="lucide-list-todo"
        title={dgettext("ui", "还没有任务")}
      >
        <:action :if={@shell.can_create_task? and not @archived?}>
          <.button variant="primary" icon="lucide-plus" patch={@new_task_path}>
            {dgettext("ui", "新建任务")}
          </.button>
        </:action>
      </.empty_state>

      <.confirm_dialog
        :if={@can_manage?}
        id="archive-project-dialog"
        title={dgettext("ui", "归档项目 %{key}？", key: @project.key)}
        confirm_label={dgettext("ui", "归档")}
        on_confirm="archive"
      >
        {dgettext("ui", "归档后不能在其中新建任务，已有任务照常可读、可编辑、可迁移。")}
      </.confirm_dialog>

      <.side_panel
        :if={@can_manage?}
        id="edit-project"
        show={@edit != nil}
        title={dgettext("ui", "编辑项目")}
        patch_on_close={@close_path}
      >
        <.form
          for={%{}}
          as={:project}
          id="edit-project-form"
          phx-change="edit_project_change"
          phx-submit="edit_project_save"
          class="flex flex-col gap-4"
        >
          <.input
            id="edit-project-key"
            name="project[key]"
            label="Key"
            value={@project.key}
            readonly
            help={dgettext("ui", "Key 创建后不能修改")}
            class="font-mono"
          />
          <.input
            id="edit-project-name"
            name="project[name]"
            label={dgettext("ui", "名称")}
            value={@edit.params["name"]}
            errors={Map.get(@edit.errors, :name, [])}
          />
          <.input
            type="textarea"
            id="edit-project-description"
            name="project[description]"
            label={dgettext("ui", "描述")}
            value={@edit.params["description"]}
            errors={Map.get(@edit.errors, :description, [])}
            rows="5"
          />
        </.form>
        <:footer :let={cancel}>
          <span />
          <div class="flex items-center gap-2">
            <.button phx-click={cancel}>{dgettext("ui", "取消")}</.button>
            <.button type="submit" form="edit-project-form" variant="primary">
              {dgettext("ui", "保存")}
            </.button>
          </div>
        </:footer>
      </.side_panel>
    </Layouts.app>
    """
  end

  defp project_menu(archived?, uri) do
    edit = %{
      id: "project-menu-edit",
      label: dgettext("ui", "编辑项目"),
      icon: "lucide-pencil",
      patch: Url.put_params(uri, %{panel: "edit-project"})
    }

    if archived? do
      [
        edit,
        %{
          id: "project-menu-unarchive",
          label: dgettext("ui", "恢复项目"),
          icon: "lucide-archive-restore",
          on_select: "unarchive"
        }
      ]
    else
      [
        edit,
        %{
          id: "project-menu-archive",
          label: dgettext("ui", "归档项目"),
          icon: "lucide-archive",
          on_select: JS.exec("data-show", to: "#archive-project-dialog")
        }
      ]
    end
  end

  defp dimensions(assigns) do
    [
      %{
        key: :status,
        label: dgettext("ui", "状态"),
        options: Enum.map(Filter.statuses(), &{&1, TaskComponents.status_label(&1)})
      },
      %{
        key: :label,
        label: dgettext("ui", "标签"),
        single: true,
        options: Enum.map(assigns.label_options, &{&1, &1})
      },
      %{
        key: :assignee,
        label: dgettext("ui", "执行方"),
        single: true,
        options: [
          {"@none", dgettext("ui", "未指派")} | Enum.map(assigns.assignable, &{&1.name, &1.name})
        ]
      }
    ]
  end
end
