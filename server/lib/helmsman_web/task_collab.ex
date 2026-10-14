defmodule HelmsmanWeb.TaskCollab do
  @moduledoc """
  The collaboration parts of the task page (add-collaboration-ui D4–D7, D10): the
  关联 section with its add panel and unlink dialog, an epic's 步骤 section with the
  attach panel, and a step's 所属 Epic row with its picker panel. `TaskLive.Show`
  forwards the `collab_*` events, `{:task_picked, …}` and the epic's project summaries
  here and renders the components.

  State: `socket.assigns.collab` —
  `%{can_link?, link_panel, unlink, epic_panel, epic, epic_id, epic_topic, gen}`.

  A step shows its epic's progress: `sync/1` locates the epic, subscribes to its
  project's topic and only then reads the summary it shows (D10), so a sibling step
  finishing in between is never missed.
  """
  use HelmsmanWeb, :html

  import Phoenix.LiveView, only: [put_flash: 3]

  require Logger

  alias Helmsman.{Events, Links, Policy, Tasks}
  alias HelmsmanWeb.{CollabComponents, FormErrors, TaskComponents, Url}

  ## State

  @doc "Initial state; call before the first `sync/1`."
  def init(socket) do
    scope = socket.assigns.current_scope

    assign(socket, :collab, %{
      can_link?: Policy.authorize(scope, :link_tasks) == :ok,
      link_panel: nil,
      unlink: nil,
      epic_panel: nil,
      epic: nil,
      epic_id: nil,
      epic_topic: nil,
      gen: 0
    })
  end

  @doc """
  Follows the task's epic (D10): with a new epic, locate it, subscribe to its project
  topic (then drop the old one) and read the summary shown. Unchanged: nothing.
  """
  def sync(socket) do
    collab = socket.assigns.collab
    wanted = socket.assigns.task[:epic]

    cond do
      wanted == nil -> clear_epic(socket)
      wanted == collab.epic_id and collab.epic != nil -> socket
      true -> follow_epic(socket, wanted)
    end
  end

  defp follow_epic(socket, ident) do
    scope = socket.assigns.current_scope

    case Tasks.get(scope, ident) do
      {:ok, epic} ->
        socket =
          if Phoenix.LiveView.connected?(socket) do
            after_locate(ident)
            resubscribe(socket, Events.topic(:project, epic.project_id))
          else
            socket
          end

        summary =
          case Tasks.get(scope, ident) do
            {:ok, again} -> Tasks.summary(again)
            {:error, _} -> Tasks.summary(epic)
          end

        update_collab(socket, &%{&1 | epic: summary, epic_id: ident})

      {:error, _} ->
        clear_epic(socket)
    end
  end

  # Test hook between locating the epic and subscribing, connected only (tasks 4.4).
  defp after_locate(ident) do
    case Application.get_env(:helmsman, :collab_after_locate) do
      fun when is_function(fun, 1) -> fun.(ident)
      _ -> :ok
    end
  end

  defp resubscribe(socket, topic) do
    case socket.assigns.collab.epic_topic do
      ^topic ->
        socket

      old ->
        Events.subscribe(topic)
        if old, do: Phoenix.PubSub.unsubscribe(Helmsman.PubSub, old)
        update_collab(socket, &%{&1 | epic_topic: topic})
    end
  end

  defp clear_epic(socket) do
    collab = socket.assigns.collab

    if collab.epic_topic, do: Phoenix.PubSub.unsubscribe(Helmsman.PubSub, collab.epic_topic)

    if collab.epic == nil and collab.epic_id == nil and collab.epic_topic == nil,
      do: socket,
      else: update_collab(socket, &%{&1 | epic: nil, epic_id: nil, epic_topic: nil})
  end

  defp update_collab(socket, fun), do: assign(socket, :collab, fun.(socket.assigns.collab))

  ## Messages

  @doc """
  A summary from the epic's project topic: updates the 所属 Epic row when it is the
  task's epic, ignored otherwise.
  """
  def handle_summary(socket, %{id: id} = summary) do
    if id == socket.assigns.collab.epic_id,
      do: update_collab(socket, &%{&1 | epic: summary}),
      else: socket
  end

  @doc "A pick of one of the panels' task pickers."
  def handle_picked(socket, picker_id, summary) do
    collab = socket.assigns.collab

    cond do
      collab.link_panel && picker_id == link_picker_id(collab) ->
        update_collab(socket, &%{&1 | link_panel: %{&1.link_panel | picked: summary, top: nil}})

      collab.epic_panel && picker_id == epic_picker_id(collab) ->
        update_collab(socket, &%{&1 | epic_panel: %{&1.epic_panel | picked: summary, top: nil}})

      true ->
        socket
    end
  end

  defp link_picker_id(collab), do: "link-picker-#{collab.gen}"
  defp epic_picker_id(collab), do: "epic-picker-#{collab.gen}"

  ## Events

  @doc "The `collab_*` events of the page; `refresh` re-reads the task."
  def handle_event(event, params, socket, refresh)

  def handle_event("collab_link_open", _params, socket, _refresh) do
    if socket.assigns.collab.can_link? do
      socket
      |> update_collab(&%{&1 | gen: &1.gen + 1})
      |> update_collab(&%{&1 | link_panel: %{relation: "depends-out", picked: nil, top: nil}})
    else
      socket
    end
  end

  def handle_event("collab_link_close", _params, socket, _refresh),
    do: update_collab(socket, &%{&1 | link_panel: nil})

  def handle_event("collab_link_change", %{"link" => %{"relation" => relation}}, socket, _refresh) do
    if socket.assigns.collab.link_panel &&
         relation in Enum.map(CollabComponents.relation_options(), &elem(&1, 1)) do
      update_collab(socket, &%{&1 | link_panel: %{&1.link_panel | relation: relation, top: nil}})
    else
      socket
    end
  end

  def handle_event("collab_link_submit", _params, socket, refresh) do
    %{collab: %{link_panel: panel}, task: task, current_scope: scope} = socket.assigns

    with %{picked: %{id: other}} <- panel,
         {type, from, to} <- CollabComponents.relation(panel.relation, task.id, other) do
      case Links.add(scope, from, to, type) do
        {:ok, _detail} ->
          socket
          |> update_collab(&%{&1 | link_panel: nil})
          |> refresh.()
          |> put_flash(:info, dgettext("ui", "已添加关联"))

        {:error, :forbidden} ->
          socket
          |> update_collab(&%{&1 | link_panel: nil})
          |> put_flash(:error, dgettext("ui", "没有权限执行此操作"))

        {:error, reason} ->
          update_collab(socket, &%{&1 | link_panel: %{panel | top: link_error(reason)}})
      end
    else
      _ -> socket
    end
  end

  def handle_event("collab_unlink_ask", %{"key" => key, "task" => other}, socket, _refresh) do
    link =
      Enum.find(
        socket.assigns.task[:links] || [],
        &(CollabComponents.group_key(&1) == key and &1.task == other)
      )

    if link && socket.assigns.collab.can_link?,
      do: update_collab(socket, &%{&1 | unlink: link}),
      else: socket
  end

  def handle_event("collab_unlink_dismiss", _params, socket, _refresh),
    do: update_collab(socket, &%{&1 | unlink: nil})

  def handle_event(
        "collab_unlink",
        %{"type" => type, "from" => from, "to" => to},
        socket,
        refresh
      ) do
    socket = update_collab(socket, &%{&1 | unlink: nil})

    case Links.remove(socket.assigns.current_scope, from, to, type) do
      {:ok, _detail} ->
        socket |> refresh.() |> put_flash(:info, dgettext("ui", "已删除关联"))

      {:error, reason} ->
        socket |> refresh.() |> put_flash(:error, link_error(reason))
    end
  end

  def handle_event("collab_epic_open", %{"mode" => mode}, socket, _refresh)
      when mode in ~w(attach parent) do
    if socket.assigns.can_edit? do
      socket
      |> update_collab(&%{&1 | gen: &1.gen + 1})
      |> update_collab(
        &%{
          &1
          | epic_panel: %{
              mode: String.to_existing_atom(mode),
              picked: nil,
              top: nil,
              version: socket.assigns.task.lock_version
            }
        }
      )
    else
      socket
    end
  end

  def handle_event("collab_epic_close", _params, socket, _refresh),
    do: update_collab(socket, &%{&1 | epic_panel: nil})

  # 挂上已有任务 (D7): the picked task joins this epic.
  def handle_event("collab_epic_submit", _params, socket, refresh) do
    %{collab: %{epic_panel: panel}, task: task} = socket.assigns

    case panel do
      %{mode: :attach, picked: %{} = picked} ->
        attrs = %{epic: task.id}

        case set_epic(socket, picked.id, attrs, picked.lock_version) do
          :ok ->
            socket
            |> update_collab(&%{&1 | epic_panel: nil})
            |> refresh.()
            |> put_flash(:info, dgettext("ui", "已挂上 %{id}", id: picked.id))

          {:error, text} ->
            update_collab(socket, &%{&1 | epic_panel: %{panel | top: text}})
        end

      %{mode: :parent, picked: %{} = picked} ->
        parent(socket, panel, picked.id, refresh)

      _ ->
        socket
    end
  end

  def handle_event("collab_epic_clear", _params, socket, refresh) do
    case socket.assigns.collab.epic_panel do
      %{mode: :parent} = panel -> parent(socket, panel, "", refresh)
      _ -> socket
    end
  end

  # 移出 Epic from a step row of the epic page.
  def handle_event("collab_detach", %{"task" => step} = params, socket, refresh) do
    version = parse_version(params["version"])

    case socket.assigns.can_edit? && set_epic(socket, step, %{epic: ""}, version) do
      :ok ->
        socket |> refresh.() |> put_flash(:info, dgettext("ui", "已移出 %{id}", id: step))

      {:error, text} ->
        socket |> refresh.() |> put_flash(:error, text)

      false ->
        socket
    end
  end

  def handle_event(_event, _params, socket, _refresh), do: socket

  # The task's own epic (the 所属 Epic row): saved with the version the panel opened at.
  defp parent(socket, panel, epic, refresh) do
    task = socket.assigns.task

    case set_epic(socket, task.id, %{epic: epic}, panel.version) do
      :ok ->
        socket |> update_collab(&%{&1 | epic_panel: nil}) |> refresh.()

      {:error, :stale} ->
        socket
        |> update_collab(&%{&1 | epic_panel: nil})
        |> refresh.()
        |> put_flash(:error, dgettext("ui", "此任务已被其他人修改，已加载最新内容"))

      {:error, text} ->
        update_collab(socket, &%{&1 | epic_panel: %{panel | top: text}})
    end
  end

  defp set_epic(socket, ident, attrs, version) do
    case Tasks.update(socket.assigns.current_scope, ident, attrs, version) do
      {:ok, _task} ->
        :ok

      {:error, :stale} when ident == socket.assigns.task.id ->
        {:error, :stale}

      {:error, :stale} ->
        {:error, dgettext("ui", "%{id} 已被修改，请重试", id: ident)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:error, changeset_text(changeset)}

      {:error, :forbidden} ->
        {:error, dgettext("ui", "没有权限执行此操作")}

      {:error, :not_found} ->
        {:error, dgettext("ui", "任务 %{id} 不存在", id: ident)}

      {:error, reason} ->
        Logger.error("Epic change of #{ident} failed: #{inspect(reason)}")
        {:error, dgettext("ui", "操作失败，请稍后重试")}
    end
  end

  defp changeset_text(changeset) do
    {message, _} =
      Keyword.get(changeset.errors, :epic) || Keyword.get(changeset.errors, :kind) ||
        {nil, []}

    CollabComponents.epic_error(message) ||
      changeset |> FormErrors.messages() |> Map.values() |> List.flatten() |> List.first()
  end

  defp link_error(reason) do
    case CollabComponents.link_error(reason) do
      nil ->
        Logger.error("Link change failed: #{inspect(reason)}")
        dgettext("ui", "操作失败，请稍后重试")

      text ->
        text
    end
  end

  defp parse_version(value) when is_integer(value), do: value

  defp parse_version(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp parse_version(_value), do: nil

  ## Rendering

  attr :collab, :map, required: true
  attr :task, :map, required: true
  attr :slug, :string, required: true

  @doc "The 关联 section (D4)."
  def links_section(assigns) do
    assigns =
      assign(assigns,
        groups: CollabComponents.link_groups(assigns.task[:links] || []),
        cancelled?: assigns.task.status == "cancelled"
      )

    ~H"""
    <section id="task-links" aria-labelledby="task-links-title" class="scroll-mt-16">
      <div class="mb-1 flex items-center justify-between gap-2">
        <h2 id="task-links-title" class="text-label font-medium text-fg-muted">
          {dgettext("ui", "关联")}
        </h2>
        <.button
          :if={@collab.can_link?}
          id="task-links-add"
          size="xs"
          icon="lucide-plus"
          phx-click="collab_link_open"
        >
          {dgettext("ui", "添加")}
        </.button>
      </div>
      <p :if={@groups == []} id="task-links-empty" class="text-body text-fg-subtle">
        {dgettext("ui", "没有关联")}
      </p>
      <div :for={{key, title, links} <- @groups} id={"task-links-#{key}"} class="mt-2">
        <h3 class="text-caption font-medium text-fg-subtle">{title}</h3>
        <ul class="mt-0.5 flex flex-col">
          <li
            :for={link <- links}
            id={"task-link-#{key}-#{link.task}"}
            data-waiting-for={link.waiting_for}
            class="group flex min-h-8 min-w-0 items-center gap-2 rounded-field px-1 -mx-1 hover:bg-hover"
          >
            <.status_icon status={link.status} class="flex-none" />
            <.task_id_link ident={link.task} workspace={@slug} status={link.status} class="flex-none" />
            <span class="min-w-0 flex-1 truncate text-body text-fg" title={link.title}>
              {link.title}
            </span>
            <CollabComponents.epic_badge kind={link[:kind]} />
            <.link_note link={link} key={key} cancelled?={@cancelled?} />
            <button
              :if={@collab.can_link?}
              type="button"
              id={"task-link-#{key}-#{link.task}-remove"}
              phx-click="collab_unlink_ask"
              phx-value-key={key}
              phx-value-task={link.task}
              aria-label={dgettext("ui", "删除关联")}
              class="inline-flex size-6 flex-none items-center justify-center rounded-field text-fg-subtle opacity-0 hover:bg-selected hover:text-fg focus-visible:opacity-100 group-hover:opacity-100 max-lg:opacity-100"
            >
              <.icon name="lucide-unlink" class="size-3.5" />
            </button>
          </li>
        </ul>
      </div>
    </section>
    """
  end

  attr :link, :map, required: true
  attr :key, :string, required: true
  attr :cancelled?, :boolean, required: true

  defp link_note(%{key: "depends-out", link: %{waiting_for: nil}} = assigns) do
    ~H"""
    <span class="inline-flex flex-none items-center gap-1 text-caption text-success-fg" data-satisfied>
      <.icon name="lucide-check" class="size-3" />{dgettext("ui", "已满足")}
    </span>
    """
  end

  defp link_note(%{key: "depends-out"} = assigns) do
    ~H"""
    <span class="flex-none text-caption text-warning-fg">
      {dgettext("ui", "在等：%{what}", what: CollabComponents.waiting_for_text(@link.waiting_for))}
    </span>
    """
  end

  defp link_note(%{key: "replaces-in", cancelled?: true} = assigns) do
    ~H"""
    <.tooltip
      id={"task-link-lock-#{@link.task}"}
      text={dgettext("ui", "被 %{id} 替代，删除这条关联之前不能恢复", id: @link.task)}
      class="flex-none"
    >
      <span
        role="img"
        aria-describedby={"task-link-lock-#{@link.task}"}
        data-locked
        class="inline-flex"
      >
        <.icon name="lucide-lock-keyhole" class="size-3.5 text-fg-muted" />
      </span>
    </.tooltip>
    """
  end

  defp link_note(assigns), do: ~H""

  attr :collab, :map, required: true
  attr :task, :map, required: true
  attr :slug, :string, required: true
  attr :can_edit?, :boolean, required: true
  attr :can_create?, :boolean, required: true
  attr :agents, :map, default: %{}
  attr :appearance, :map, default: %{}
  attr :uri, :string, required: true

  @doc "An epic's 步骤 section (D7); nothing for a task."
  def steps_section(%{task: %{kind: "epic"}} = assigns) do
    progress = assigns.task.progress || %{total: 0, done: 0, by_status: %{}}

    assigns =
      assign(assigns,
        progress: progress,
        counts: CollabComponents.status_counts(progress),
        children: assigns.task[:children] || []
      )

    ~H"""
    <section id="task-epic" aria-labelledby="task-epic-title">
      <div class="mb-1 flex items-center justify-between gap-2">
        <h2 id="task-epic-title" class="text-label font-medium text-fg-muted">
          {dgettext("ui", "步骤")}
          <span id="task-epic-count" class="ml-1 font-mono tabular-nums text-fg-subtle">
            {@progress.done}/{@progress.total}
          </span>
        </h2>
        <div class="flex items-center gap-1">
          <.button
            :if={@can_create?}
            id="epic-add-step"
            size="xs"
            icon="lucide-plus"
            patch={Url.put_params(@uri, %{panel: "new", epic: @task.id})}
          >
            {dgettext("ui", "添加步骤")}
          </.button>
          <.button
            :if={@can_edit?}
            id="epic-attach"
            size="xs"
            icon="lucide-link-2"
            phx-click={JS.push("collab_epic_open", value: %{mode: "attach"})}
          >
            {dgettext("ui", "挂上已有任务")}
          </.button>
        </div>
      </div>
      <%= if @progress.total == 0 do %>
        <p id="task-epic-empty" class="text-body text-fg-subtle">{dgettext("ui", "还没有步骤")}</p>
      <% else %>
        <CollabComponents.progress_bar id="task-epic-progress" progress={@progress} class="my-2" />
        <ul id="task-epic-counts" class="flex flex-wrap gap-x-3 gap-y-1 text-caption text-fg-muted">
          <li
            :for={{status, n} <- @counts}
            data-status={status}
            class="inline-flex items-center gap-1"
          >
            <.status_icon status={status} />{TaskComponents.status_label(status)}
            <span class="font-mono tabular-nums text-fg">{n}</span>
          </li>
        </ul>
        <ol id="task-epic-steps" class="mt-2 flex flex-col">
          <li
            :for={step <- @children}
            id={"epic-step-#{step.id}"}
            class="group flex min-h-8 min-w-0 items-center gap-2 rounded-field px-1 -mx-1 hover:bg-hover"
          >
            <.status_icon status={step.status} class="flex-none" />
            <.task_id_link ident={step.id} workspace={@slug} status={step.status} class="flex-none" />
            <span class="min-w-0 flex-1 truncate text-body text-fg" title={step.title}>
              {step.title}
            </span>
            <.icon
              :if={step.blocked}
              name="lucide-octagon-pause"
              class="size-3.5 flex-none text-warning"
              label={dgettext("ui", "被阻塞")}
              data-blocked
            />
            <TaskComponents.actor_ref
              :if={step.assignee}
              actor={step.assignee}
              agents={@agents}
              appearance={@appearance}
              compact
            />
            <.dropdown
              :if={@can_edit?}
              id={"epic-step-#{step.id}-menu"}
              label={dgettext("ui", "%{id} 的操作", id: step.id)}
              align={:end}
              trigger_class="h-6 w-6 justify-center"
              items={[
                %{
                  id: "epic-step-#{step.id}-detach",
                  label: dgettext("ui", "移出 Epic"),
                  icon: "lucide-unlink",
                  on_select: "collab_detach",
                  value: %{task: step.id, version: step.lock_version}
                }
              ]}
            >
              <:trigger><.icon name="lucide-ellipsis" class="size-4" /></:trigger>
            </.dropdown>
          </li>
        </ol>
      <% end %>
    </section>
    """
  end

  def steps_section(assigns), do: ~H""

  attr :collab, :map, required: true
  attr :task, :map, required: true
  attr :slug, :string, required: true
  attr :can_edit?, :boolean, required: true

  @doc "The 所属 Epic property row of a task (D7); nothing for an epic."
  def epic_row(%{task: %{kind: "epic"}} = assigns), do: ~H""

  def epic_row(assigns) do
    assigns = assign(assigns, :epic, assigns.collab.epic)

    ~H"""
    <.property_row label={dgettext("ui", "Epic")} id="task-epic-field">
      <div class="flex min-w-0 flex-1 items-center gap-2">
        <%= if @task.epic do %>
          <.task_id_link
            ident={@task.epic}
            workspace={@slug}
            title={(@epic && @epic.title) || @task[:epic_title]}
            class="min-w-0 whitespace-nowrap"
          />
          <CollabComponents.epic_progress
            :if={@epic}
            id="task-epic-field-progress"
            progress={@epic.progress}
            bar={false}
          />
        <% else %>
          <span class="text-fg-subtle">—</span>
        <% end %>
        <button
          :if={@can_edit?}
          type="button"
          id="task-epic-edit"
          phx-click={JS.push("collab_epic_open", value: %{mode: "parent"})}
          aria-label={dgettext("ui", "修改所属 Epic")}
          class="ml-auto inline-flex size-6 flex-none items-center justify-center rounded-field text-fg-subtle hover:bg-hover hover:text-fg"
        >
          <.icon name="lucide-pencil" class="size-3.5" />
        </button>
      </div>
    </.property_row>
    """
  end

  attr :collab, :map, required: true
  attr :task, :map, required: true
  attr :scope, :map, required: true

  @doc "The panels and dialog: add link, unlink confirmation, epic picker / attach."
  def overlays(assigns) do
    ~H"""
    <.link_panel collab={@collab} task={@task} scope={@scope} />
    <.unlink_dialog collab={@collab} task={@task} />
    <.epic_panel collab={@collab} task={@task} scope={@scope} />
    """
  end

  defp link_panel(%{collab: %{link_panel: nil}} = assigns) do
    ~H"""
    <.side_panel id="link-panel" show={false} title="" on_cancel={JS.push("collab_link_close")}>
      <div />
    </.side_panel>
    """
  end

  defp link_panel(assigns) do
    %{collab: collab, task: task} = assigns
    panel = collab.link_panel

    existing =
      for link <- task[:links] || [],
          CollabComponents.group_key(link) == panel.relation,
          do: link.task

    consequence =
      with %{} = picked <- panel.picked,
           {type, from, to} <- CollabComponents.relation(panel.relation, task.id, picked.id) do
        ends = %{task.id => task, picked.id => picked}
        CollabComponents.consequence(type, ends[from], ends[to])
      else
        _ -> nil
      end

    assigns =
      assign(assigns,
        panel: panel,
        picker_id: link_picker_id(collab),
        exclude: [task.id | existing],
        consequence: consequence
      )

    ~H"""
    <.side_panel
      id="link-panel"
      show
      title={dgettext("ui", "添加关联 · %{id}", id: @task.id)}
      dirty={@panel.picked != nil}
      on_cancel={JS.push("collab_link_close")}
    >
      <:error :if={@panel.top}><span id="link-panel-error">{@panel.top}</span></:error>
      <div class="flex flex-col gap-4">
        <.form
          for={%{}}
          as={:link}
          id="link-form"
          phx-change="collab_link_change"
          phx-submit="collab_link_submit"
        >
          <.input
            type="radio"
            id="link-kind"
            name="link[relation]"
            label={dgettext("ui", "关系")}
            value={@panel.relation}
            options={CollabComponents.relation_options()}
          />
        </.form>
        <.live_component
          module={HelmsmanWeb.TaskPicker}
          id={@picker_id}
          scope={@scope}
          label={dgettext("ui", "任务")}
          exclude={@exclude}
        />
        <div
          :if={@consequence}
          id="link-consequence"
          data-tone={elem(@consequence, 0)}
          class={[
            "flex items-start gap-2 rounded-field border px-3 py-2 text-body",
            if(elem(@consequence, 0) == :warning,
              do: "border-warning tint-warning text-warning-fg",
              else: "border-border tint-info text-info-fg"
            )
          ]}
        >
          <.icon
            name={
              if(elem(@consequence, 0) == :warning, do: "lucide-triangle-alert", else: "lucide-info")
            }
            class="mt-0.5 size-4 flex-none"
          />
          <span>{elem(@consequence, 1)}</span>
        </div>
      </div>
      <:footer :let={cancel}>
        <span />
        <div class="flex items-center gap-2">
          <.button phx-click={cancel}>{dgettext("ui", "取消")}</.button>
          <.button
            id="link-submit"
            type="submit"
            form="link-form"
            variant="primary"
            disabled={@panel.picked == nil}
          >
            {dgettext("ui", "添加")}
          </.button>
        </div>
      </:footer>
    </.side_panel>
    """
  end

  defp unlink_dialog(assigns) do
    link = assigns.collab.unlink

    assigns =
      assign(assigns,
        link: link,
        value:
          link &&
            (fn {from, to} -> %{type: link.type, from: from, to: to} end).(
              CollabComponents.ends(link, assigns.task.id)
            ),
        text: link && CollabComponents.unlink_text(link, assigns.task.id)
      )

    ~H"""
    <.confirm_dialog
      id="unlink-dialog"
      show={@link != nil}
      title={dgettext("ui", "删除关联")}
      confirm_label={dgettext("ui", "删除")}
      danger
      on_confirm="collab_unlink"
      confirm_value={@value || %{}}
      on_cancel={JS.push("collab_unlink_dismiss")}
    >
      {@text}
    </.confirm_dialog>
    """
  end

  # What attaching the picked task means (D7).
  defp attach_note(%{mode: :attach, picked: %{kind: "epic"}}, _task),
    do: {:warning, dgettext("ui", "Epic 不能属于另一个 Epic")}

  defp attach_note(%{mode: :attach, picked: %{} = picked}, task) do
    case picked[:epic] do
      old when old in [nil, task.id] -> nil
      old -> {:info, dgettext("ui", "它会从 %{old} 移到这里", old: old)}
    end
  end

  defp attach_note(_panel, _task), do: nil

  defp epic_panel(%{collab: %{epic_panel: nil}} = assigns) do
    ~H"""
    <.side_panel id="epic-panel" show={false} title="" on_cancel={JS.push("collab_epic_close")}>
      <div />
    </.side_panel>
    """
  end

  defp epic_panel(assigns) do
    %{collab: collab, task: task} = assigns
    panel = collab.epic_panel

    {title, exclude, epic_only, submit} =
      case panel.mode do
        :attach ->
          {dgettext("ui", "挂上已有任务 · %{id}", id: task.id),
           [task.id | Enum.map(task[:children] || [], & &1.id)], false, dgettext("ui", "挂上")}

        :parent ->
          {dgettext("ui", "所属 Epic · %{id}", id: task.id), Enum.reject([task[:epic]], &is_nil/1),
           true, dgettext("ui", "保存")}
      end

    note = attach_note(panel, task)

    assigns =
      assign(assigns,
        panel: panel,
        title: title,
        picker_id: epic_picker_id(collab),
        exclude: exclude,
        epic_only: epic_only,
        submit: submit,
        note: note
      )

    ~H"""
    <.side_panel
      id="epic-panel"
      show
      title={@title}
      dirty={@panel.picked != nil}
      on_cancel={JS.push("collab_epic_close")}
    >
      <:error :if={@panel.top}><span id="epic-panel-error">{@panel.top}</span></:error>
      <div class="flex flex-col gap-4">
        <p :if={@panel.mode == :parent} class="text-body text-fg-muted">
          {dgettext("ui", "选择这个任务所属的 Epic。不输入时列出本项目的 Epic；其他项目的 Epic 输入 ID 或标题查找。")}
        </p>
        <.live_component
          module={HelmsmanWeb.TaskPicker}
          id={@picker_id}
          scope={@scope}
          label={if(@epic_only, do: dgettext("ui", "Epic"), else: dgettext("ui", "任务"))}
          project_key={@task.project_key}
          epic_only={@epic_only}
          exclude={@exclude}
        />
        <p
          :if={@note}
          id="epic-panel-note"
          class={[
            "text-caption",
            if(elem(@note, 0) == :warning, do: "text-warning-fg", else: "text-fg-muted")
          ]}
        >
          {elem(@note, 1)}
        </p>
      </div>
      <:footer :let={cancel}>
        <.button
          :if={@panel.mode == :parent and @task[:epic] != nil}
          id="epic-panel-clear"
          icon="lucide-unlink"
          phx-click="collab_epic_clear"
        >
          {dgettext("ui", "移出 Epic")}
        </.button>
        <span :if={!(@panel.mode == :parent and @task[:epic] != nil)} />
        <div class="flex items-center gap-2">
          <.button phx-click={cancel}>{dgettext("ui", "取消")}</.button>
          <.button
            id="epic-panel-submit"
            variant="primary"
            phx-click="collab_epic_submit"
            disabled={@panel.picked == nil}
          >
            {@submit}
          </.button>
        </div>
      </:footer>
    </.side_panel>
    """
  end
end
