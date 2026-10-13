defmodule HelmsmanWeb.NewTaskPanel do
  @moduledoc """
  新建任务 side panel (design D3), rendered by `HelmsmanWeb.Layouts.app/1` on every
  workspace page and opened by `?panel=new` in the current URL (sidebar entry, C,
  command palette, task list header).

  Not rendered for members without `:create_task` (`shell.can_create_task?`) or for the
  `/dev/ui` demo scope. The default project is the one of the current task list or task
  page, otherwise the first unarchived project.

  With 连续创建 on, a successful submit keeps the panel open, clears title and
  description and shows 已创建 <ID> in a live region inside the panel until a field
  changes; component flashes are not used because they only reach the page on
  navigation.
  """
  use HelmsmanWeb, :live_component

  alias Ecto.Changeset
  alias Helmsman.Accounts.Scope
  alias Helmsman.Tasks

  alias HelmsmanWeb.{
    CollabComponents,
    FormErrors,
    LocalRepositoryComponents,
    RunComponents,
    RunData,
    TaskComponents,
    TaskData,
    Url
  }

  @impl true
  def mount(socket) do
    {:ok,
     assign(socket,
       open?: false,
       params: %{},
       errors: %{},
       top_error: nil,
       created: nil,
       continuous: false,
       assignable: [],
       availability: %{},
       epic_options: [],
       epic_preset: nil
     )}
  end

  @impl true
  def update(assigns, socket) do
    open? = open?(assigns.scope, assigns.shell)
    socket = assign(socket, id: assigns.id, scope: assigns.scope, shell: assigns.shell)
    socket = if open? and not socket.assigns.open?, do: reset(socket), else: socket
    {:ok, assign(socket, :open?, open?)}
  end

  defp open?(%Scope{workspace: %{}}, %{can_create_task?: true, uri: uri}) when is_binary(uri),
    do: uri |> URI.parse() |> Map.get(:query) |> panel() == "new"

  defp open?(_scope, _shell), do: false

  defp panel(nil), do: nil
  defp panel(query), do: query |> URI.decode_query() |> Map.get("panel")

  # 添加步骤 opens the panel with `epic=<ID>` (add-collaboration-ui D7).
  defp preset_epic(%{uri: uri}) when is_binary(uri) do
    case URI.parse(uri).query do
      nil -> nil
      query -> query |> URI.decode_query() |> Map.get("epic") |> blank_to_nil()
    end
  end

  defp preset_epic(_shell), do: nil

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(text), do: if(String.trim(text) == "", do: nil, else: String.trim(text))

  defp reset(socket) do
    %{scope: scope, shell: shell} = socket.assigns

    preset = preset_epic(shell) |> preset_summary(scope)

    socket
    |> assign(
      params: %{
        "kind" => "task",
        "epic" => (preset && preset.id) || "",
        "project" => default_project(shell),
        "title" => "",
        "description" => "",
        "priority" => "medium",
        "labels" => "",
        "assignee" => "",
        "start" => "true"
      },
      errors: %{},
      top_error: nil,
      created: nil,
      continuous: false,
      assignable: TaskData.assignable(scope),
      availability: availability(scope),
      epic_preset: preset
    )
    |> load_epics()
  end

  defp preset_summary(nil, _scope), do: nil

  defp preset_summary(ident, scope) do
    case Tasks.get(scope, ident) do
      {:ok, %{kind: :epic} = task} -> Tasks.summary(task)
      _ -> nil
    end
  end

  # The epics of the chosen project, plus the preset one from another project.
  defp load_epics(socket) do
    %{scope: scope, params: params, epic_preset: preset} = socket.assigns

    epics =
      case Tasks.list(scope, params["project"] || "", kind: :epic, limit: 200) do
        {:ok, tasks} -> Enum.map(tasks, &Tasks.summary/1)
        {:error, _} -> []
      end

    epics =
      if preset && not Enum.any?(epics, &(&1.id == preset.id)),
        do: [preset | epics],
        else: epics

    assign(socket, :epic_options, Enum.map(epics, &{"#{&1.id} #{&1.title}", &1.id}))
  end

  defp availability(scope) do
    case RunData.availability(scope) do
      {:ok, availability} -> TaskData.with_squads(scope, availability)
      {:error, _} -> %{}
    end
  end

  @doc false
  def default_project(%{projects: projects, path: path}) do
    keys = Enum.map(projects, & &1.key)

    current =
      case String.split(path || "", "/", trim: true) do
        ["w", _slug, "p", key | _] -> String.upcase(key)
        ["w", _slug, "t", ident | _] -> ident |> String.split("-") |> hd() |> String.upcase()
        _ -> nil
      end

    if current in keys, do: current, else: List.first(keys)
  end

  @impl true
  def handle_event("change", %{"task" => params}, socket) do
    old_project = socket.assigns.params["project"]

    socket =
      assign(socket,
        params: Map.merge(socket.assigns.params, Map.take(params, fields())),
        continuous: params["continuous"] == "true",
        created: nil
      )

    socket =
      if socket.assigns.params["project"] != old_project, do: load_epics(socket), else: socket

    {:noreply, socket}
  end

  def handle_event("submit", %{"task" => raw}, socket) do
    continuous = Map.get(raw, "continuous", to_string(socket.assigns.continuous)) == "true"
    params = Map.merge(socket.assigns.params, Map.take(raw, fields()))
    socket = assign(socket, params: params, continuous: continuous)
    %{scope: scope} = socket.assigns

    attrs = %{
      title: params["title"],
      description: params["description"],
      priority: params["priority"],
      labels: split_labels(params["labels"]),
      assignee: params["assignee"],
      kind: if(params["kind"] == "epic", do: "epic", else: "task")
    }

    attrs = if attrs.kind == "task", do: Map.put(attrs, :epic, params["epic"] || ""), else: attrs

    # `start` only means something for a managed agent (design D11).
    attrs =
      if Map.has_key?(socket.assigns.availability, params["assignee"]),
        do: Map.put(attrs, :start, params["start"] != "false"),
        else: attrs

    case Tasks.create(scope, params["project"] || "", attrs) do
      {:ok, task} -> {:noreply, created(socket, task)}
      {:error, reason} -> {:noreply, failed(socket, reason)}
    end
  end

  defp fields, do: ~w(project title description priority labels assignee start kind epic)

  @doc false
  def split_labels(nil), do: []

  def split_labels(text),
    do: text |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))

  defp created(socket, task) do
    path = "/w/#{socket.assigns.scope.workspace.slug}/t/#{task.ident}"

    if socket.assigns.continuous do
      params = %{socket.assigns.params | "title" => "", "description" => ""}

      assign(socket,
        params: params,
        errors: %{},
        top_error: nil,
        created: %{ident: task.ident, path: path}
      )
    else
      socket |> put_dispatch_flash(Map.get(task, :dispatch)) |> push_navigate(to: path)
    end
  end

  defp put_dispatch_flash(socket, outcomes) do
    case RunComponents.dispatch_flash(outcomes) do
      nil -> socket
      {:info, text} -> put_flash(socket, :info, text)
      {:warning, text} -> put_flash(socket, :error, text)
    end
  end

  defp failed(socket, %Changeset{} = changeset) do
    errors =
      changeset
      |> FormErrors.messages()
      |> Map.merge(epic_errors(changeset))

    assign(socket, errors: errors, top_error: nil, created: nil)
  end

  defp failed(socket, :project_archived),
    do: field_error(socket, :project, dgettext("ui", "项目已归档，不能新建任务"))

  defp failed(socket, :not_found), do: field_error(socket, :project, dgettext("ui", "项目不存在"))

  defp failed(socket, :forbidden),
    do: assign(socket, top_error: dgettext("ui", "没有权限执行此操作"), errors: %{}, created: nil)

  defp failed(socket, reason) do
    require Logger
    Logger.error("NewTaskPanel: Tasks.create failed: #{inspect(reason)}")
    assign(socket, top_error: dgettext("ui", "操作失败，请稍后重试"), errors: %{}, created: nil)
  end

  # The domain's epic and kind messages are English (add-collaboration-ui D7).
  defp epic_errors(changeset) do
    for {field, {message, _}} <- changeset.errors,
        field in [:epic, :kind],
        text = CollabComponents.epic_error(message),
        into: %{},
        do: {field, [text]}
  end

  defp field_error(socket, field, message),
    do: assign(socket, errors: %{field => [message]}, top_error: nil, created: nil)

  @impl true
  def render(assigns) do
    assigns =
      assign(assigns,
        close: if(assigns.open?, do: Url.drop_params(assigns.shell.uri, ["panel"])),
        dirty: dirty?(assigns.params),
        can_create_project?: can_create_project?(assigns.scope)
      )

    ~H"""
    <div id={@id}>
      <.side_panel
        id="new-task-dialog"
        show={@open?}
        title={dgettext("ui", "新建任务")}
        dirty={@dirty}
        patch_on_close={@close}
      >
        <:error :if={@top_error}>{@top_error}</:error>
        <div :if={@shell.projects == []} id="new-task-no-projects">
          <.empty_state
            icon="lucide-folder"
            title={dgettext("ui", "还没有项目")}
            description={
              if(@can_create_project?,
                do: nil,
                else: dgettext("ui", "请联系管理员创建项目")
              )
            }
          >
            <:action :if={@can_create_project?}>
              <.button
                variant="primary"
                navigate={"/w/#{@scope.workspace.slug}/projects?panel=new-project"}
              >
                {dgettext("ui", "新建项目")}
              </.button>
            </:action>
          </.empty_state>
        </div>
        <div
          :if={@shell.projects != []}
          id="new-task-created"
          role="status"
          aria-live="polite"
          class="empty:hidden"
        >
          <p
            :if={@created}
            id={"new-task-created-#{@created.ident}"}
            class="mb-4 flex items-center gap-2 rounded-field border border-border tint-success px-3 py-2 text-body"
          >
            <.icon name="lucide-circle-check" class="size-4 text-success" />
            {dgettext("ui", "已创建")}
            <.task_id_link ident={@created.ident} workspace={@scope.workspace.slug} />
          </p>
        </div>
        <.form
          :if={@shell.projects != []}
          for={%{}}
          as={:task}
          id="new-task-form"
          phx-change="change"
          phx-submit="submit"
          phx-target={@myself}
          class="flex flex-col gap-4"
        >
          <.input
            type="select"
            id="new-task-project"
            name="task[project]"
            label={dgettext("ui", "项目")}
            value={@params["project"]}
            options={Enum.map(@shell.projects, &{"#{&1.name}（#{&1.key}）", &1.key})}
            errors={Map.get(@errors, :project, [])}
          />
          <.input
            type="radio"
            id="new-task-kind"
            name="task[kind]"
            label={dgettext("ui", "种类")}
            value={@params["kind"]}
            options={[{dgettext("ui", "任务"), "task"}, {"Epic", "epic"}]}
            help={
              if(@params["kind"] == "epic",
                do: dgettext("ui", "Epic 是一组步骤的容器，进度按步骤计算，全部步骤完成时自动完成")
              )
            }
            errors={Map.get(@errors, :kind, [])}
          />
          <.input
            :if={@params["kind"] != "epic"}
            type="select"
            id="new-task-epic"
            name="task[epic]"
            label={dgettext("ui", "所属 Epic")}
            value={@params["epic"]}
            options={[{dgettext("ui", "无"), ""} | @epic_options]}
            errors={Map.get(@errors, :epic, [])}
          />
          <.input
            id="new-task-title"
            name="task[title]"
            label={dgettext("ui", "标题")}
            value={@params["title"]}
            errors={Map.get(@errors, :title, [])}
            autocomplete="off"
            phx-debounce="200"
          />
          <.input
            type="textarea"
            id="new-task-description"
            name="task[description]"
            label={dgettext("ui", "描述")}
            value={@params["description"]}
            errors={Map.get(@errors, :description, [])}
            rows="6"
            phx-debounce="200"
          />
          <div class="grid grid-cols-1 gap-4 sm:grid-cols-2">
            <.input
              type="select"
              id="new-task-priority"
              name="task[priority]"
              label={dgettext("ui", "优先级")}
              value={@params["priority"]}
              options={TaskComponents.priority_options()}
              errors={Map.get(@errors, :priority, [])}
            />
            <.input
              type="select"
              id="new-task-assignee"
              name="task[assignee]"
              label={dgettext("ui", "执行方")}
              value={@params["assignee"]}
              options={assignee_options(@assignable)}
              errors={Map.get(@errors, :assignee, [])}
            />
          </div>
          <div
            :if={@availability[@params["assignee"]]}
            id="new-task-start-group"
            class="flex flex-col gap-1"
          >
            <.input
              type="switch"
              id="new-task-start"
              name="task[start]"
              label={dgettext("ui", "创建后立即开始")}
              checked={@params["start"] != "false"}
            />
            <p
              :if={other_machine(@shell, @params, @availability)}
              id="new-task-other-machine"
              class="flex items-start gap-1 text-caption text-warning-fg"
            >
              <.icon name="lucide-triangle-alert" class="mt-0.5 size-3.5 flex-none" />
              {other_machine(@shell, @params, @availability)}
            </p>
            <p
              :if={
                !other_machine(@shell, @params, @availability) &&
                  start_note(@params["assignee"], @availability[@params["assignee"]])
              }
              id="new-task-start-note"
              class="text-caption text-fg-muted"
            >
              {start_note(@params["assignee"], @availability[@params["assignee"]])}
            </p>
          </div>
          <.input
            id="new-task-labels"
            name="task[labels]"
            label={dgettext("ui", "标签")}
            help={dgettext("ui", "多个标签用逗号分隔")}
            value={@params["labels"]}
            errors={Map.get(@errors, :labels, [])}
            autocomplete="off"
            phx-debounce="200"
          />
          <.input
            type="switch"
            id="new-task-continuous"
            name="task[continuous]"
            label={dgettext("ui", "连续创建")}
            help={dgettext("ui", "创建后保留面板，继续填写下一个任务")}
            checked={@continuous}
          />
        </.form>
        <:footer :let={cancel}>
          <span />
          <div class="flex items-center gap-2">
            <.button phx-click={cancel}>{dgettext("ui", "取消")}</.button>
            <.button
              :if={@shell.projects != []}
              type="submit"
              form="new-task-form"
              variant="primary"
            >
              {dgettext("ui", "创建")}
            </.button>
          </div>
        </:footer>
      </.side_panel>
    </div>
    """
  end

  # add-local-repositories-ui D10: the chosen project's local repository is on another
  # machine than the agent's runtime.
  defp other_machine(shell, %{"project" => key, "assignee" => agent}, availability) do
    local =
      case Enum.find(shell.projects, &(&1.key == key)) do
        nil -> nil
        project -> Map.get(project, :local_repository)
      end

    LocalRepositoryComponents.other_machine(local, agent, availability[agent])
  end

  defp start_note(name, %{result: {:skipped, _}} = entry),
    do: TaskData.unavailable_text(name, entry) <> dgettext("ui", "，创建后不会启动运行")

  defp start_note(squad, %{kind: :squad, leader: leader} = entry) do
    case entry.runtime do
      %{status: "offline", daemon_name: machine} ->
        dgettext(
          "ui",
          "%{squad} 的 leader %{leader} 的运行时（%{machine}）当前离线，运行会排队，等它上线后开始",
          squad: squad,
          leader: leader,
          machine: machine
        )

      _ ->
        dgettext("ui", "%{squad} 的 leader %{leader} 会排队运行，由它决定谁来做",
          squad: squad,
          leader: leader
        )
    end
  end

  defp start_note(agent, %{runtime: %{status: "offline", daemon_name: machine}}),
    do:
      dgettext("ui", "%{agent} 的运行时（%{machine}）当前离线，运行会排队，等它上线后开始",
        agent: agent,
        machine: machine
      )

  defp start_note(_agent, _availability), do: nil

  # Grouped like the assignee menu (add-squads-autopilots-ui D6): 人, Agent, 小队.
  defp assignee_options(assignable) do
    groups =
      for {kind, label} <- [
            {"human", dgettext("ui", "人")},
            {"agent", "Agent"},
            {"squad", dgettext("ui", "小队")}
          ],
          names = for(a <- assignable, to_string(a.kind) == kind, do: {a.name, a.name}),
          names != [],
          do: {label, names}

    [{dgettext("ui", "未指派"), ""} | groups]
  end

  defp dirty?(params),
    do: Enum.any?(~w(title description labels), &(String.trim(params[&1] || "") != ""))

  defp can_create_project?(%Scope{} = scope),
    do: Helmsman.Policy.authorize(scope, :create_project) == :ok

  defp can_create_project?(_scope), do: false
end
