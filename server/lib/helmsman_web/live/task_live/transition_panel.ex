defmodule HelmsmanWeb.TaskLive.TransitionPanel do
  @moduledoc "Shared, server-authoritative evidence and reason transition panel."
  use HelmsmanWeb, :live_component
  alias Helmsman.GitHub.PullRequests
  alias Helmsman.{Policy, Tasks}
  alias Helmsman.Tasks.StateMachine

  alias HelmsmanWeb.{
    GitHubComponents,
    MarkdownEditor,
    TaskEvidence,
    TaskLocalBranch,
    TaskTransitions
  }

  alias HelmsmanWeb.TaskLive.TransitionErrors

  @impl true
  def mount(socket),
    do: {:ok, assign(socket, panel: nil, session: 0, version: nil, local_branch: nil)}

  @impl true
  def update(%{event: event, params: params}, socket),
    do: handle_event(event, params, socket) |> then(fn {:noreply, s} -> {:ok, s} end)

  def update(assigns, socket) do
    changed =
      assigns[:version] != socket.assigns.version or assigns[:ident] != socket.assigns[:ident] or
        not Map.has_key?(socket.assigns, :task)

    socket = assign(socket, assigns) |> assign(:current_scope, assigns.scope)
    socket = if changed, do: reload(socket), else: socket
    {:ok, check_panel(socket)}
  end

  defp reload(socket) do
    case Tasks.get(socket.assigns.scope, socket.assigns.ident) do
      {:ok, task} ->
        socket |> assign(:task, Tasks.detail(task)) |> TaskLocalBranch.load(Tasks.detail(task))

      {:error, _} ->
        assign(socket, :panel, nil)
    end
  end

  @impl true
  def handle_event("open_transition", %{"to" => to} = params, socket) do
    socket = reload(socket)
    task = socket.assigns.task

    button =
      Enum.find(
        TaskTransitions.buttons(task.status, allowed(task.status)),
        &(&1.to == to and &1.kind != :direct)
      )

    if Policy.authorize(socket.assigns.scope, :transition_task) == :ok and
         params["from"] == task.status and button do
      preview = if to == "verified", do: preview(socket.assigns.scope, task.id), else: nil

      panel = %{
        to: to,
        from: task.status,
        kind: button.kind,
        label: button.label,
        params: %{"result" => "none"},
        errors: %{},
        top: nil,
        blocked: nil,
        preview: preview
      }

      {:noreply, socket |> update(:session, &(&1 + 1)) |> assign(:panel, panel)}
    else
      send(self(), {:transition_panel, :refresh, socket.assigns.ident})
      {:noreply, socket}
    end
  end

  def handle_event("close_transition", _params, socket) do
    send(self(), {:transition_panel, :closed, socket.assigns.ident})
    {:noreply, assign(socket, :panel, nil)}
  end

  def handle_event("transition_change", %{"transition" => params} = form, socket) do
    {:noreply,
     if(current_session?(socket, form),
       do: update_panel(socket, &%{&1 | params: params}),
       else: socket
     )}
  end

  def handle_event("submit_transition", %{"transition" => params} = form, socket) do
    panel = socket.assigns.panel

    if panel == nil or panel.blocked != nil or not current_session?(socket, form) do
      {:noreply, socket}
    else
      socket = update_panel(socket, &%{&1 | params: params})
      kind = if panel.kind == :reason, do: "reason", else: "evidence"

      case TaskEvidence.parse(Map.merge(params, %{"kind" => kind, "to" => panel.to})) do
        {:error, errors} -> {:noreply, update_panel(socket, &%{&1 | errors: errors, top: nil})}
        {:ok, opts} -> {:noreply, submit(socket, panel, opts)}
      end
    end
  end

  defp submit(socket, panel, opts) do
    case Tasks.transition(
           socket.assigns.scope,
           socket.assigns.ident,
           panel.to,
           Map.put(opts, :expected_from, panel.from)
         ) do
      {:ok, _detail} ->
        send(self(), {:transition_panel, :done, socket.assigns.ident})
        assign(socket, :panel, nil)

      {:error, reason} ->
        case TransitionErrors.message(reason, panel.label) do
          {:blocked, text} ->
            send(self(), {:transition_panel, :refresh, socket.assigns.ident})
            socket |> reload() |> update_panel(&%{&1 | blocked: text, errors: %{}, top: nil})

          {{:field, field}, text} ->
            update_panel(socket, &%{&1 | errors: %{field => text}, top: nil})

          {:top, text} ->
            update_panel(socket, &%{&1 | top: text, errors: %{}})
        end
    end
  end

  defp check_panel(%{assigns: %{panel: %{blocked: nil} = panel, task: task}} = socket) do
    if task.status != panel.from or panel.to not in Enum.map(allowed(task.status), &to_string/1) do
      {:blocked, text} = TransitionErrors.message({:status_changed, task.status}, panel.label)
      update_panel(socket, &%{&1 | blocked: text})
    else
      socket
    end
  end

  defp check_panel(socket), do: socket
  defp allowed(status), do: StateMachine.allowed(String.to_existing_atom(status))

  defp preview(scope, ident) do
    case PullRequests.verify_preview(scope, ident) do
      {:ok, preview} -> preview
      _ -> nil
    end
  end

  defp update_panel(%{assigns: %{panel: nil}} = socket, _fun), do: socket
  defp update_panel(socket, fun), do: update(socket, :panel, fun)

  defp current_session?(%{assigns: %{panel: %{kind: :reason}, session: session}}, form),
    do: MarkdownEditor.session_of(%{"session" => form["editor_session"]}) == session

  defp current_session?(_socket, _form), do: true

  defp passed_tests(%{last_done_tests: %{passed: true} = tests}), do: tests
  defp passed_tests(_hint), do: nil

  @impl true
  def render(%{panel: nil} = assigns) do
    ~H"""
    <div id="panel-host" class="contents">
      <.side_panel
        id="transition-panel"
        show={false}
        title=""
        on_cancel={JS.push("close_transition", target: @myself)}
      >
        <div />
      </.side_panel>
    </div>
    """
  end

  def render(assigns) do
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
    <div id="panel-host" class="contents">
      <.side_panel
        id="transition-panel"
        show
        title={"#{@panel.label} #{@task.id}"}
        dirty
        focus={if(@panel.kind == :reason, do: "#transition-editor-input-#{@session}")}
        on_cancel={JS.push("close_transition", target: @myself)}
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
        <TaskLocalBranch.verify_preview
          :if={@panel.to == "verified" and @local_branch != nil}
          state={@local_branch}
        />
        <GitHubComponents.merge_preview :if={@panel.kind == :evidence} preview={@panel[:preview]} />
        <.form
          for={%{}}
          as={:transition}
          id="transition-form"
          phx-target={@myself}
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
    </div>
    """
  end
end
