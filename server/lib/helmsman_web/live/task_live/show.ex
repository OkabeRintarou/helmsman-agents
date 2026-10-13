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

  require Logger

  alias Helmsman.{Events, Feedback, Policy, Tasks}
  alias Helmsman.Tasks.StateMachine

  alias HelmsmanWeb.{
    FeedbackComponents,
    FeedbackTimeline,
    FormErrors,
    Markdown,
    MarkdownEditor,
    RunActions,
    RunComponents,
    RunData,
    RunLog,
    TaskComponents,
    TaskData,
    TaskEvidence,
    TaskRuns,
    TaskTransitions,
    Throttle
  }

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
    agents = TaskData.agent_info(scope)

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
       can_feedback?: Policy.authorize(scope, :add_feedback) == :ok,
       editing: %{"title" => nil, "description" => nil},
       field_errors: %{},
       labels_draft: nil,
       agents: agents,
       assignable: TaskData.assignable(scope, agents),
       availability: availability(scope),
       assign_confirm: nil,
       label_options: TaskData.labels(scope, detail.project_key),
       transition_panel: nil,
       feedback_panel: nil,
       feedback_html: %{},
       description_html: nil,
       revisable: revisable(scope, detail.id),
       fresh_after: detail.feedback |> Enum.map(& &1.seq) |> Enum.max(fn -> 0 end),
       # Editing sessions (design D14): one more for every new edit, never reused.
       feedback_session: 0,
       description_session: 0,
       transition_session: 0
     )
     |> assign(:uri, "/w/#{scope.workspace.slug}/t/#{detail.id}")
     |> cache_rendered()
     |> TaskRuns.init()
     |> TaskRuns.load()
     |> RunLog.init()
     |> RunActions.init()
     |> then(
       &if(connected?(&1), do: push_event(&1, "hm:visit-task", %{ident: detail.id}), else: &1)
     )}
  end

  @impl true
  def handle_params(%{"ident" => ident} = params, uri, socket) do
    canonical = socket.assigns.task.id

    if ident != canonical do
      %URI{path: path, query: query} = URI.parse(uri)
      path = String.replace_suffix(path, "/t/#{ident}", "/t/#{canonical}")
      to = if query, do: "#{path}?#{query}", else: path
      {:noreply, push_navigate(socket, to: to, replace: true)}
    else
      %URI{path: path, query: query} = URI.parse(uri)

      socket =
        socket
        |> assign(:uri, if(query, do: "#{path}?#{query}", else: path))
        |> open_run_log(params["run"])

      {:noreply, socket}
    end
  end

  # `?run=<id>` opens the run log modal (design D9).
  defp open_run_log(socket, nil), do: RunLog.close(socket)

  defp open_run_log(socket, id) do
    case Integer.parse(id) do
      {id, ""} -> RunLog.open(socket, id)
      _ -> RunLog.close(socket)
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

      socket =
        if field == "description",
          do: update(socket, :description_session, &(&1 + 1)),
          else: socket

      {:noreply,
       assign(socket,
         editing: editing,
         field_errors: Map.delete(socket.assigns.field_errors, field)
       )}
    else
      {:noreply, socket}
    end
  end

  def handle_event("draft_field", %{"field" => field, "value" => value} = params, socket)
      when field in @fields do
    if current_session?(socket, field, params),
      do: {:noreply, update_editing(socket, field, &%{&1 | draft: value})},
      else: {:noreply, socket}
  end

  def handle_event("save_field", %{"field" => field, "value" => value} = params, socket)
      when field in @fields do
    case current_session?(socket, field, params) && socket.assigns.editing[field] do
      falsy when falsy in [nil, false] ->
        {:noreply, socket}

      edit ->
        socket = update_editing(socket, field, fn _ -> %{edit | draft: value} end)
        attrs = %{String.to_existing_atom(field) => value}
        {:noreply, save(socket, field, attrs, edit.version)}
    end
  end

  def handle_event("cancel_field", %{"field" => field} = params, socket) when field in @fields do
    if current_session?(socket, field, params) do
      {:noreply,
       assign(socket,
         editing: Map.put(socket.assigns.editing, field, nil),
         field_errors: Map.delete(socket.assigns.field_errors, field)
       )}
    else
      {:noreply, socket}
    end
  end

  ## Priority, assignee and labels

  # Choosing a managed agent for a new or in-progress task asks first (design D11).
  def handle_event("set_field", %{"field" => "assignee", "value" => value} = params, socket) do
    %{task: task, availability: availability} = socket.assigns
    version = parse_version(params["version"]) || task.lock_version
    current = task.assignee && task.assignee.name

    case availability[value] do
      %{} = agent when value != current and task.status in ["new", "in_progress"] ->
        confirm = %{agent: value, version: version, availability: agent}
        {:noreply, assign(socket, :assign_confirm, confirm)}

      _ ->
        {:noreply, save(socket, "assignee", %{assignee: value}, version)}
    end
  end

  # The buttons that promise not to start always submit `start: false` (D11). The
  # dialog pushes JSON (`true`), `phx-value-*` would send `"true"`.
  def handle_event("confirm_assign", %{"agent" => agent, "start" => start} = params, socket) do
    version = parse_version(params["version"]) || socket.assigns.task.lock_version
    attrs = %{assignee: agent, start: start in [true, "true"]}
    {:noreply, socket |> assign(:assign_confirm, nil) |> save("assignee", attrs, version)}
  end

  def handle_event("dismiss_assign", _params, socket),
    do: {:noreply, assign(socket, :assign_confirm, nil)}

  ## Runs (design D8)

  def handle_event("runs_" <> _ = event, _params, socket),
    do: {:noreply, TaskRuns.handle_event(event, socket)}

  def handle_event("run_log_" <> _ = event, params, socket),
    do: {:noreply, RunLog.handle_event(event, params, socket)}

  def handle_event(event, params, socket)
      when event in ~w(ask_cancel_run dismiss_cancel_run cancel_run retry_run),
      do: {:noreply, RunActions.handle_event(event, params, socket, &TaskRuns.load/1)}

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

        {:noreply,
         socket
         |> update(:transition_session, &(&1 + 1))
         |> assign(:transition_panel, panel)}
    end
  end

  def handle_event("close_transition", _params, socket),
    do: {:noreply, assign(socket, :transition_panel, nil)}

  def handle_event("transition_change", %{"transition" => params} = form, socket) do
    if transition_session?(socket, form),
      do: {:noreply, update_panel(socket, &%{&1 | params: params})},
      else: {:noreply, socket}
  end

  def handle_event("submit_transition", %{"transition" => params} = form, socket) do
    panel = socket.assigns.transition_panel

    if panel == nil or panel.blocked != nil or not transition_session?(socket, form) do
      {:noreply, socket}
    else
      socket = update_panel(socket, &%{&1 | params: params})
      kind = if panel.kind == :reason, do: "reason", else: "evidence"

      case TaskEvidence.parse(Map.merge(params, %{"kind" => kind, "to" => panel.to})) do
        {:error, errors} ->
          {:noreply, update_panel(socket, &%{&1 | errors: errors, top: nil})}

        {:ok, opts} ->
          {:noreply, run_transition(socket, panel, opts)}
      end
    end
  end

  ## Feedback (design D5)

  def handle_event("open_feedback", %{"mode" => mode} = params, socket)
      when mode in ~w(add answer revise) do
    case socket.assigns.can_feedback? && build_feedback_panel(socket, mode, params["target"]) do
      panel when is_map(panel) ->
        session = socket.assigns.feedback_session + 1

        {:noreply,
         assign(socket,
           feedback_session: session,
           feedback_panel: Map.put(panel, :session, session)
         )}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("close_feedback", _params, socket),
    do: {:noreply, assign(socket, :feedback_panel, nil)}

  def handle_event("feedback_change", %{"feedback" => params} = form, socket) do
    if feedback_session?(socket, form) do
      {:noreply,
       update_feedback_panel(socket, fn panel ->
         %{panel | kind: kind_param(panel, params), content: params["content"] || panel.content}
       end)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("submit_feedback", %{"feedback" => params} = form, socket) do
    panel = socket.assigns.feedback_panel

    if panel == nil or panel.blocked != nil or not feedback_session?(socket, form) do
      {:noreply, socket}
    else
      content = params["content"] || ""
      kind = kind_param(panel, params)
      socket = update_feedback_panel(socket, &%{&1 | kind: kind, content: content})
      {:noreply, submit_feedback(socket, panel, %{kind: kind, content: content})}
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
  def handle_info({:feedback_added, _view}, socket), do: {:noreply, refresh(socket)}

  def handle_info({:run_events, _id, _events} = message, socket),
    do: run_log_info(message, socket)

  def handle_info({:run_updated, _summary} = message, socket), do: run_log_info(message, socket)

  def handle_info({:runs_changed, _ident}, socket),
    do: {:noreply, Throttle.schedule(socket, :reload_runs)}

  def handle_info(:reload_runs, socket),
    do: {:noreply, socket |> Throttle.done(:reload_runs) |> TaskRuns.load()}

  def handle_info(message, socket) when message in [{:agents_changed}, {:runtimes_changed}],
    do: {:noreply, assign(socket, :availability, availability(socket.assigns.current_scope))}

  ## Helpers

  defp save(socket, field, attrs, version) do
    %{current_scope: scope, task: task} = socket.assigns

    case Tasks.update(scope, task.id, attrs, version) do
      {:ok, updated} ->
        socket
        |> put_dispatch_flash(Map.get(updated, :dispatch))
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
        Logger.error("Task update failed: #{inspect(reason)}")
        put_flash(socket, :error, dgettext("ui", "操作失败，请稍后重试"))
    end
  end

  defp run_log_info(message, socket) do
    case RunLog.handle_info(message, socket) do
      {:ok, socket} -> {:noreply, socket}
      :ignore -> {:noreply, socket}
    end
  end

  defp put_dispatch_flash(socket, outcomes) do
    case RunComponents.dispatch_flash(outcomes) do
      nil -> socket
      {:info, text} -> put_flash(socket, :info, text)
      {:warning, text} -> put_flash(socket, :error, text)
    end
  end

  defp availability(scope) do
    case RunData.availability(scope) do
      {:ok, availability} -> availability
      {:error, _} -> %{}
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
      label_options: label_options,
      revisable: revisable(socket.assigns.current_scope, detail.id)
    )
    |> cache_rendered()
    |> check_panel()
    |> check_feedback_panel()
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

  ## Editing sessions (design D14)

  defp current_session?(socket, "description", params) do
    session =
      MarkdownEditor.session_of(%{"session" => params["session"] || params["editor_session"]})

    session == socket.assigns.description_session
  end

  defp current_session?(_socket, _field, _params), do: true

  # A reason panel's form must come from the current reason editor; evidence panels
  # have no editor.
  defp transition_session?(socket, form) do
    case socket.assigns.transition_panel do
      %{kind: :reason} ->
        MarkdownEditor.session_of(%{"session" => form["editor_session"]}) ==
          socket.assigns.transition_session

      _ ->
        true
    end
  end

  defp feedback_session?(socket, form) do
    case socket.assigns.feedback_panel do
      nil -> false
      panel -> MarkdownEditor.session_of(%{"session" => form["editor_session"]}) == panel.session
    end
  end

  ## Feedback helpers

  defp build_feedback_panel(_socket, "add", _target),
    do: new_feedback_panel(:add, nil, "comment", "")

  defp build_feedback_panel(socket, "answer", target) do
    case find_feedback(socket, target) do
      %{kind: "question", status: "active"} = question ->
        quote = %{
          id: question.id,
          seq: question.seq,
          text: TaskComponents.excerpt(question.content, 140)
        }

        %{new_feedback_panel(:answer, question.id, "answer", "") | quote: quote}

      _ ->
        nil
    end
  end

  defp build_feedback_panel(socket, "revise", target) do
    with true <- MapSet.member?(socket.assigns.revisable, target),
         %{status: "active"} = entry <- find_feedback(socket, target) do
      new_feedback_panel(:revise, entry.id, entry.kind, entry.content)
    else
      _ -> nil
    end
  end

  defp new_feedback_panel(mode, target, kind, content) do
    %{
      mode: mode,
      target: target,
      kind: kind,
      initial: content,
      content: content,
      quote: nil,
      errors: %{},
      top: nil,
      blocked: nil
    }
  end

  defp find_feedback(socket, id), do: Enum.find(socket.assigns.task.feedback, &(&1.id == id))

  defp kind_param(%{mode: :answer}, _params), do: "answer"

  defp kind_param(panel, params) do
    if params["kind"] in ~w(comment review question answer), do: params["kind"], else: panel.kind
  end

  defp update_feedback_panel(socket, fun) do
    case socket.assigns.feedback_panel do
      nil -> socket
      panel -> assign(socket, :feedback_panel, fun.(panel))
    end
  end

  defp submit_feedback(socket, panel, attrs) do
    %{current_scope: scope, task: task} = socket.assigns

    result =
      case panel.mode do
        :revise -> Feedback.revise(scope, panel.target, attrs)
        _ -> Feedback.add(scope, task.id, attrs)
      end

    case result do
      {:ok, entry} ->
        socket
        |> assign(:feedback_panel, nil)
        |> refresh()
        |> push_event("hm:scroll-to", %{id: "feedback-#{entry.seq}"})

      {:error, %Ecto.Changeset{} = changeset} ->
        messages = FormErrors.messages(changeset)

        errors =
          %{
            content: FormErrors.first(messages, :content),
            kind: FormErrors.first(messages, :kind)
          }
          |> Map.reject(fn {_field, text} -> is_nil(text) end)

        update_feedback_panel(socket, &%{&1 | errors: errors, top: nil})

      {:error, {:superseded, latest}} ->
        socket
        |> refresh()
        |> update_feedback_panel(&%{&1 | blocked: superseded_text(latest), errors: %{}, top: nil})

      {:error, reason} ->
        update_feedback_panel(socket, &%{&1 | top: feedback_error(reason), errors: %{}})
    end
  end

  defp feedback_error(:forbidden), do: dgettext("ui", "没有权限执行此操作")
  defp feedback_error(:not_found), do: dgettext("ui", "任务不存在")

  defp feedback_error(reason) do
    Logger.error("Feedback write failed: #{inspect(reason)}")
    dgettext("ui", "操作失败，请稍后重试")
  end

  defp superseded_text(latest),
    do: dgettext("ui", "这条 Feedback 已被修订为 %{id}，请修订最新版本", id: latest)

  # An open revision whose record was revised meanwhile can no longer be submitted.
  defp check_feedback_panel(socket) do
    case socket.assigns.feedback_panel do
      %{mode: :revise, blocked: nil, target: target} ->
        case find_feedback(socket, target) do
          %{superseded_by: next} = entry when is_binary(next) ->
            latest =
              Enum.find(
                socket.assigns.task.feedback,
                &(&1.thread_seq == entry.thread_seq and &1.status == "active")
              )

            update_feedback_panel(
              socket,
              &%{&1 | blocked: superseded_text((latest || %{id: next}).id)}
            )

          _ ->
            socket
        end

      _ ->
        socket
    end
  end

  defp revisable(scope, ident) do
    case Feedback.revisable_ids(scope, ident) do
      {:ok, ids} -> ids
      {:error, _} -> MapSet.new()
    end
  end

  # Feedback never changes: each record is rendered once (design D2); the description
  # again only when it changed.
  defp cache_rendered(socket) do
    %{task: task, feedback_html: cache, current_scope: scope} = socket.assigns

    rendered =
      for view <- task.feedback, not Map.has_key?(cache, view.seq), into: cache do
        {view.seq, render_feedback(view, scope)}
      end

    description_html =
      case socket.assigns.description_html do
        {content, _html} = cached when content == task.description ->
          cached

        _ ->
          {task.description, Markdown.to_html(task.description, scope: scope, anchor_ns: "desc")}
      end

    assign(socket, feedback_html: rendered, description_html: description_html)
  end

  @doc false
  # Emits [:helmsman_web, :feedback, :render] so tests can see what was rendered.
  def render_feedback(view, scope) do
    :telemetry.execute([:helmsman_web, :feedback, :render], %{count: 1}, %{id: view.id})

    Markdown.to_html(view.content,
      scope: scope,
      anchor_ns: "fb-#{view.seq}",
      mentions: view.mentions
    )
  end

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
        working: TaskRuns.working_agents(assigns.task_runs),
        verify_lock: verify_lock(assigns.task_runs),
        assignees: assignee_options(assigns.assignable, assigns.task.assignee),
        availability: assigns.availability,
        open_question:
          assigns.task.open_question && FeedbackTimeline.last_open_question(assigns.task.feedback)
      )

    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} shell={@shell}>
      <:header>
        <.page_header title={@task.id}>
          <:crumb navigate={"/w/#{@slug}/p/#{@task.project_key}"}>{@task.project_key}</:crumb>
          <:actions>
            <a
              :if={@task.open_question}
              id="task-open-question"
              href={"#feedback-#{@open_question && @open_question.seq}"}
              class="inline-flex rounded-badge"
            >
              <.badge tone={:warning}>
                <.icon name="lucide-circle-question-mark" class="size-3.5" />{dgettext("ui", "待回答")}
              </.badge>
            </a>
            <.working_chip
              id="task-working"
              agents={@working}
              on_click={working_click(@task_runs, @uri)}
            />
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
            <.transition_button
              :for={button <- @primary}
              button={button}
              from={@task.status}
              lock={@verify_lock}
            />
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
            html={elem(@description_html, 1)}
            scope={@current_scope}
            session={@description_session}
            candidates={@assignable}
          />
          <FeedbackComponents.timeline
            feedback={@task.feedback}
            html={@feedback_html}
            scope={@current_scope}
            revisable={@revisable}
            can_feedback?={@can_feedback?}
            fresh_after={@fresh_after}
            agents={@agents}
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
                  items={assignee_items(@assignees, @task, @availability)}
                  trigger_class="h-7 px-1.5 -mx-1.5 min-w-0"
                >
                  <:trigger>
                    <TaskComponents.actor_ref actor={@task.assignee} agents={@agents} />
                  </:trigger>
                </.dropdown>
                <TaskComponents.actor_ref
                  :if={!@can_edit?}
                  actor={@task.assignee}
                  agents={@agents}
                />
                <.field_error error={@field_errors["assignee"]} />
              </.property_row>
              <.property_row label={dgettext("ui", "提出方")} id="task-creator">
                <TaskComponents.actor_ref actor={@task.created_by} agents={@agents} />
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
          <TaskRuns.section
            state={@task_runs}
            stream={@streams.task_runs}
            scope={@current_scope}
            uri={@uri}
            managed_assignee?={
              @task.assignee != nil and Map.has_key?(@availability, @task.assignee.name)
            }
          />
          <section aria-labelledby="task-history-title">
            <h2 id="task-history-title" class="mb-1 text-label font-medium text-fg-muted">
              {dgettext("ui", "历史")}
            </h2>
            <ol id="task-history" class="flex flex-col divide-y divide-border">
              <TaskComponents.history_entry
                :for={{entry, i} <- Enum.with_index(@task.history)}
                id={"history-#{i}"}
                entry={entry}
                agents={@agents}
              />
            </ol>
          </section>
        </aside>
      </div>
      <.transition_panel
        panel={@transition_panel}
        task={@task}
        scope={@current_scope}
        session={@transition_session}
        candidates={@assignable}
      />
      <.feedback_panel
        panel={@feedback_panel}
        task={@task}
        scope={@current_scope}
        candidates={@assignable}
      />
      <.assign_confirm confirm={@assign_confirm} task={@task} />
      <.modal
        id="run-log-modal"
        show={@run_log != nil}
        size={:xl}
        title={if(@run_log, do: dgettext("ui", "执行记录 · 运行 #%{id}", id: @run_log.id), else: "")}
        patch_on_close={HelmsmanWeb.Url.drop_params(@uri, ["run"])}
      >
        <RunLog.log :if={@run_log} log={@run_log} events={@streams.run_events} scope={@current_scope} />
      </.modal>
      <RunActions.dialog stop_run={@stop_run} />
    </Layouts.app>
    """
  end

  attr :confirm, :map, default: nil
  attr :task, :map, required: true

  defp assign_confirm(assigns) do
    confirm = assigns.confirm
    available? = confirm != nil and confirm.availability.result == :ok
    agent = confirm && confirm.agent

    assigns =
      assign(assigns,
        available?: available?,
        agent: agent,
        value: confirm && %{agent: agent, version: confirm.version},
        text: confirm && assign_confirm_text(confirm)
      )

    ~H"""
    <.confirm_dialog
      id="assign-confirm"
      show={@confirm != nil}
      title={
        if(@confirm,
          do: dgettext("ui", "把 %{task} 指派给 %{agent}", task: @task.id, agent: @agent),
          else: ""
        )
      }
      confirm_label={if(@available?, do: dgettext("ui", "开始"), else: dgettext("ui", "仍然指派（不会启动运行）"))}
      on_confirm="confirm_assign"
      confirm_value={Map.put(@value || %{}, :start, @available?)}
      on_cancel={JS.push("dismiss_assign")}
    >
      {@text}
      <:secondary_action
        :if={@available?}
        label={dgettext("ui", "暂不开始")}
        event="confirm_assign"
        value={Map.put(@value, :start, false)}
      />
    </.confirm_dialog>
    """
  end

  defp assign_confirm_text(%{agent: agent, availability: %{result: :ok, runtime: runtime}}) do
    case runtime do
      %{status: "offline", daemon_name: machine} ->
        dgettext("ui", "%{agent} 的运行时（%{machine}）当前离线，运行会排队，等它上线后开始",
          agent: agent,
          machine: machine
        )

      _ ->
        dgettext("ui", "开始后 %{agent} 会立即排队运行；暂不开始只指派，不启动运行", agent: agent)
    end
  end

  defp assign_confirm_text(%{agent: agent, availability: %{result: result}}),
    do:
      dgettext("ui", "%{reason}。仍可指派，但不会启动运行",
        reason: RunComponents.unavailable_reason(agent, result)
      )

  attr :button, :map, required: true
  attr :from, :string, required: true
  attr :lock, :string, default: nil, doc: "why 验收 is unavailable (a run is active)"

  defp transition_button(assigns) do
    assigns = assign(assigns, :reason, if(assigns.button.to == "verified", do: assigns.lock))

    ~H"""
    <.button
      id={"transition-#{@button.to}"}
      size="sm"
      variant={if(@button.primary?, do: "primary", else: "secondary")}
      data-kind={@button.kind}
      disabled_reason={@reason}
      phx-click={transition_click(@button, @from)}
    >
      {@button.label}
    </.button>
    """
  end

  # 验收 waits for the active runs (design D8): the first one's agent explains why.
  defp verify_lock(%{active: [%{agent: agent} | _]}), do: TransitionErrors.run_active_text(agent)
  defp verify_lock(_state), do: nil

  defp working_click(%{active: [%{id: id} | _]}, uri),
    do: JS.patch(HelmsmanWeb.Url.put_params(uri, %{run: id}))

  defp working_click(_state, _uri), do: nil

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

  attr :task, :map, required: true
  attr :edit, :map, default: nil
  attr :error, :string, default: nil
  attr :can_edit?, :boolean, required: true
  attr :html, :any, required: true
  attr :scope, :map, required: true
  attr :session, :integer, required: true
  attr :candidates, :list, required: true

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
      <div :if={@task.description != ""} id="task-description-text">
        <.markdown content={@task.description} html={@html} scope={@scope} anchor_ns="desc" />
      </div>
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
        <.live_component
          module={MarkdownEditor}
          id="description-editor"
          session={@session}
          scope={@scope}
          name="value"
          value={@edit.original}
          label={dgettext("ui", "描述")}
          errors={List.wrap(@error)}
          submit={:event}
          field="description"
          rows={10}
          candidates={@candidates}
        />
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
            phx-click={JS.push("cancel_field", value: %{field: "description", session: @session})}
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

  defp assignee_items(options, task, availability) do
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
          |> Map.merge(availability_item(actor.name, availability[actor.name]))
        end)
    ]
  end

  # Unavailable agents stay selectable (the confirmation explains); the reason is the
  # item's description (design D11).
  defp availability_item(_name, nil), do: %{}

  defp availability_item(name, %{result: {:skipped, _} = result}),
    do: %{
      description: RunComponents.unavailable_reason(name, result),
      attrs: %{"data-unavailable" => "true"}
    }

  defp availability_item(_name, %{runtime: %{status: "offline"}}),
    do: %{description: dgettext("ui", "运行时离线"), attrs: %{"data-runtime-offline" => "true"}}

  defp availability_item(_name, _available), do: %{}

  defp passed_tests(%{last_done_tests: %{passed: true} = tests}), do: tests
  defp passed_tests(_hint), do: nil

  # Always rendered (closed when `panel` is nil) so that closing runs the overlay's
  # phx-remove and gives the page back its focus and pointer events.
  attr :panel, :map, default: nil
  attr :task, :map, required: true
  attr :scope, :map, required: true
  attr :session, :integer, default: 0
  attr :candidates, :list, default: []

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
      focus={if(@panel.kind == :reason, do: "#transition-editor-input-#{@session}")}
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
          <.live_component
            module={MarkdownEditor}
            id="transition-editor"
            session={@session}
            scope={@scope}
            name="transition[comment]"
            value=""
            label={dgettext("ui", "原因")}
            errors={List.wrap(@panel.errors[:comment])}
            submit={:form}
            rows={6}
            candidates={@candidates}
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

  # Always rendered (closed when `panel` is nil), like the transition panel.
  attr :panel, :map, default: nil
  attr :task, :map, required: true
  attr :scope, :map, required: true
  attr :candidates, :list, required: true

  defp feedback_panel(%{panel: nil} = assigns) do
    ~H"""
    <.side_panel id="feedback-panel" show={false} title="" on_cancel={JS.push("close_feedback")}>
      <div />
    </.side_panel>
    """
  end

  defp feedback_panel(assigns) do
    panel = assigns.panel

    title =
      case panel.mode do
        :revise -> dgettext("ui", "修订 %{id}", id: panel.target)
        :answer -> dgettext("ui", "回答 %{id}", id: panel.target)
        :add -> dgettext("ui", "添加 Feedback")
      end

    assigns =
      assign(assigns,
        title: title,
        dirty: String.trim(panel.content || "") != "",
        submit_label:
          if(panel.mode == :revise, do: dgettext("ui", "修订"), else: dgettext("ui", "提交"))
      )

    ~H"""
    <.side_panel
      id="feedback-panel"
      show
      title={@title}
      dirty={@dirty}
      focus={"#feedback-editor-input-#{@panel.session}"}
      on_cancel={JS.push("close_feedback")}
    >
      <:error :if={@panel.blocked || @panel.top}>
        <span id="feedback-panel-error">{@panel.blocked || @panel.top}</span>
      </:error>
      <blockquote
        :if={@panel.quote}
        id="feedback-quote"
        class="mb-4 border-l-2 border-border-strong pl-3 text-body text-fg-muted"
      >
        <a href={"#feedback-#{@panel.quote.seq}"} class="font-mono text-label hover:text-brand-fg">
          {@panel.quote.id}
        </a>
        <p class="mt-0.5 break-words">{@panel.quote.text}</p>
      </blockquote>
      <.form
        for={%{}}
        as={:feedback}
        id="feedback-form"
        phx-change="feedback_change"
        phx-submit="submit_feedback"
        class="flex flex-col gap-4"
      >
        <.input
          :if={@panel.mode != :answer}
          type="radio"
          id="feedback-kind"
          name="feedback[kind]"
          label={dgettext("ui", "种类")}
          value={@panel.kind}
          options={FeedbackComponents.kind_options()}
          errors={List.wrap(@panel.errors[:kind])}
        />
        <.live_component
          module={MarkdownEditor}
          id="feedback-editor"
          session={@panel.session}
          scope={@scope}
          name="feedback[content]"
          value={@panel.initial}
          label={dgettext("ui", "内容")}
          errors={List.wrap(@panel.errors[:content])}
          submit={:form}
          rows={8}
          placeholder={dgettext("ui", "支持 Markdown，输入 @ 提及")}
          candidates={@candidates}
        />
      </.form>
      <:footer :let={cancel}>
        <span class="text-caption text-fg-subtle"><.kbd mod>Enter</.kbd>
        {@submit_label}</span>
        <div class="flex items-center gap-2">
          <.button phx-click={cancel}>{dgettext("ui", "取消")}</.button>
          <.button
            id="feedback-submit"
            type="submit"
            form="feedback-form"
            variant="primary"
            disabled={@panel.blocked != nil}
          >
            {@submit_label}
          </.button>
        </div>
      </:footer>
    </.side_panel>
    """
  end
end
