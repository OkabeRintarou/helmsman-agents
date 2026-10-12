defmodule HelmsmanWeb.AgentLive.Show do
  @moduledoc """
  `/w/:slug/agents/*name` (spec web-agents Agent 详情页 … Agent 页实时刷新, design D4):
  a managed agent's tabs (`?tab=runs|instructions|usage`), its properties and actions
  (edit panel `?panel=edit`, disable / enable / archive); an external agent's card.

  A name in another case redirects to the lower-case address; an unknown name is a 404.
  `{:agents_changed}`, `{:runtimes_changed}` and `{:run_updated, _}` reload the agent
  through `HelmsmanWeb.Throttle`; an open edit panel keeps its input and shows a notice
  when the agent changed meanwhile (`HelmsmanWeb.AgentForm.refreshed/2`).
  """
  use HelmsmanWeb, :live_view

  import HelmsmanWeb.AgentComponents

  import HelmsmanWeb.RunComponents,
    only: [run_card: 1, cancellable?: 2, trigger_summary: 1, duration_text: 1]

  alias Helmsman.{Agents, Dispatch, Events, Members, Policy, Presence}
  alias HelmsmanWeb.{AgentForm, MarkdownEditor, RunActions, RunComponents, RunData, Throttle, Url}
  alias Phoenix.HTML.Engine

  @tabs ~w(runs instructions usage)
  @page 50
  @max_instructions 8192

  @impl true
  def mount(%{"name" => segments}, _session, socket) do
    name = Url.agent_name(segments)
    scope = socket.assigns.current_scope

    if String.downcase(name) != name do
      path = Url.agent_path(scope.workspace.slug, String.downcase(name))
      {:ok, push_navigate(socket, to: path, replace: true)}
    else
      if connected?(socket) do
        Events.subscribe(Events.topic(:workspace_runs, scope.workspace.id))
        Events.subscribe(Presence.agents_topic(scope.workspace.id))
      end

      case RunData.agent(scope, name) do
        {:ok, agent} ->
          {:ok,
           socket
           |> assign(
             page_title: agent.name,
             name: agent.name,
             tab: "runs",
             uri: nil,
             confirm: nil,
             agent_form: nil,
             form_gen: 0,
             run_panel: nil,
             member_names: member_names(scope),
             can_run?: Policy.authorize(scope, :run_agent) == :ok,
             availability: nil,
             runs: %{
               active: [],
               pending: [],
               pending_total: 0,
               pending_shown: @page,
               total: 0,
               shown: @page
             }
           )
           |> stream_configure(:agent_runs, dom_id: &"run-row-#{&1.id}")
           |> stream(:agent_runs, [])
           |> put_agent(agent)
           |> RunActions.init()
           |> load_availability()
           |> load_runs()}

        {:error, _} ->
          raise HelmsmanWeb.NotFoundError
      end
    end
  end

  defp member_names(scope) do
    case Members.list(scope) do
      {:ok, members} -> Map.new(members, &{&1.user_id, &1.display_name})
      _ -> %{}
    end
  end

  defp put_agent(socket, agent) do
    scope = socket.assigns.current_scope
    online? = agent.kind == "external" and external_online?(scope, agent.name)
    status = status(agent, if(online?, do: MapSet.new([agent.name]), else: MapSet.new()))

    assign(socket,
      agent: agent,
      status: status,
      online?: online?,
      permissions: RunData.agent_permissions(scope, agent)
    )
  end

  defp external_online?(scope, name) do
    scope.workspace.id
    |> Presence.agents_topic()
    |> Presence.list()
    |> Enum.any?(fn {_key, %{metas: metas}} -> Enum.any?(metas, &(&1[:actor_name] == name)) end)
  end

  @impl true
  def handle_params(params, uri, socket) do
    %URI{path: path, query: query} = URI.parse(uri)
    tab = if params["tab"] in @tabs, do: params["tab"], else: "runs"

    socket =
      assign(socket, uri: if(query, do: "#{path}?#{query}", else: path), tab: tab)

    socket =
      socket
      |> open_form(params["panel"] == "edit" and can_edit?(socket.assigns))
      |> open_run_panel(params["panel"] == "run" and run_state(socket.assigns) == :enabled)

    {:noreply, socket}
  end

  ## Manual runs (spec web-agents 手动运行)

  defp load_availability(%{assigns: %{can_run?: false}} = socket), do: socket

  defp load_availability(socket) do
    availability =
      case RunData.availability(socket.assigns.current_scope) do
        {:ok, map} -> map[socket.assigns.name]
        _ -> nil
      end

    assign(socket, :availability, availability)
  end

  # :hidden (viewer, external or archived agent), {:disabled, reason} or :enabled.
  defp run_state(%{can_run?: false}), do: :hidden
  defp run_state(%{agent: %{kind: "external"}}), do: :hidden
  defp run_state(%{agent: %{archived: true}}), do: :hidden
  defp run_state(%{availability: nil}), do: :hidden

  defp run_state(%{availability: %{result: result}, name: name}) do
    case RunComponents.unavailable_reason(name, result) do
      nil -> :enabled
      reason -> {:disabled, reason}
    end
  end

  defp open_run_panel(socket, false), do: assign(socket, :run_panel, nil)
  defp open_run_panel(%{assigns: %{run_panel: %{}}} = socket, true), do: socket

  defp open_run_panel(socket, true) do
    gen = socket.assigns.form_gen + 1

    assign(socket,
      form_gen: gen,
      run_panel: %{gen: gen, task: "", errors: %{}, error: nil}
    )
  end

  defp submit_run(socket, params) do
    %{run_panel: panel} = socket.assigns
    task = String.trim(params["task"] || "")
    instructions = params["instructions"] || ""
    panel = %{panel | task: task}

    if byte_size(instructions) > @max_instructions,
      do: run_error(socket, panel, :instructions, too_long()),
      else: dispatch_run(socket, panel, task, instructions)
  end

  defp dispatch_run(socket, panel, task, instructions) do
    %{current_scope: scope, name: name} = socket.assigns

    case Dispatch.run_agent(scope, name, blank(task), blank(instructions)) do
      {:ok, %{outcome: outcome, run: run}} ->
        socket
        |> assign(:run_panel, nil)
        |> put_run_flash(outcome, run)
        |> load_runs()
        |> push_patch(to: Url.drop_params(socket.assigns.uri, ["panel"]))

      {:error, reason} ->
        run_failed(socket, panel, reason)
    end
  end

  defp run_failed(socket, panel, :instructions_required),
    do: run_error(socket, panel, :instructions, dgettext("ui", "不指定任务时必须填写说明"))

  defp run_failed(socket, panel, {:invalid_instructions, :too_long}),
    do: run_error(socket, panel, :instructions, too_long())

  defp run_failed(socket, %{task: task} = panel, :not_found) when task != "",
    do: run_error(socket, panel, :task, dgettext("ui", "任务不存在"))

  defp run_failed(socket, panel, reason)
       when reason in [:task_closed, {:not_dispatched, :task_closed}],
       do: run_error(socket, panel, :task, dgettext("ui", "任务已验收或撤销"))

  defp run_failed(socket, panel, reason),
    do: assign(socket, :run_panel, %{panel | error: AgentForm.error_text(reason), errors: %{}})

  defp too_long, do: dgettext("ui", "说明不能超过 8 KB")

  defp blank(""), do: nil
  defp blank(text), do: if(String.trim(text) == "", do: nil, else: text)

  defp run_error(socket, panel, field, text),
    do: assign(socket, :run_panel, %{panel | errors: %{field => [text]}, error: nil})

  defp put_run_flash(socket, outcome, run) do
    case RunComponents.dispatch_message(outcome) do
      {:info, text} when run != nil ->
        path = "/w/#{socket.assigns.current_scope.workspace.slug}/runs/#{run.id}"

        label = dgettext("ui", "查看运行 #%{id}", id: run.id)
        put_flash(socket, :info, link_message(text, path, label, run.id))

      {:info, text} ->
        put_flash(socket, :info, text)

      {:warning, text} ->
        put_flash(socket, :error, text)
    end
  end

  # A flash with a link to the run page (escaped text and attributes).
  defp link_message(text, path, label, id) do
    escape = &Engine.html_escape/1

    {:safe,
     [
       escape.(text),
       ~s( <a href="),
       escape.(path),
       ~s(" class="text-brand-fg hover:underline" data-run-link="),
       to_string(id),
       ~s(">),
       escape.(label),
       "</a>"
     ]}
  end

  ## Runs tab (design D4, D8a)

  defp load_runs(%{assigns: %{agent: %{kind: "external"}}} = socket), do: socket

  defp load_runs(socket) do
    %{current_scope: scope, name: name, runs: state} = socket.assigns
    target = {:agent, name}

    with {:ok, open} <- RunData.open_window(scope, target, state.pending_shown),
         {:ok, finished} <- RunData.finished_window(scope, target, state.shown) do
      state = %{
        state
        | active: open.active,
          pending: open.pending,
          pending_total: open.pending_total,
          total: finished.total
      }

      socket |> assign(:runs, state) |> stream(:agent_runs, finished.runs, reset: true)
    else
      {:error, _} -> socket
    end
  end

  defp grow(socket, key) do
    state = Map.update!(socket.assigns.runs, key, &(&1 + @page))
    socket |> assign(:runs, state) |> load_runs()
  end

  defp can_edit?(%{agent: agent, permissions: p}),
    do: agent.kind == "managed" and not agent.archived and (p.configure or p.administer)

  defp open_form(socket, false), do: assign(socket, :agent_form, nil)
  defp open_form(%{assigns: %{agent_form: %{}}} = socket, true), do: socket

  defp open_form(socket, true) do
    %{current_scope: scope, agent: agent, permissions: permissions} = socket.assigns
    gen = socket.assigns.form_gen + 1

    assign(socket,
      form_gen: gen,
      agent_form: AgentForm.edit(scope, gen, agent, permissions)
    )
  end

  ## Events

  @impl true
  def handle_event("agent_form_" <> _ = event, params, socket) do
    case AgentForm.handle_event(event, params, socket) do
      {:saved, view, socket} ->
        {:noreply,
         socket
         |> put_agent(complete(socket, view))
         |> assign(:agent_form, nil)
         |> put_flash(:info, dgettext("ui", "已保存"))
         |> push_patch(to: Url.drop_params(socket.assigns.uri, ["panel"]))}

      result ->
        result
    end
  end

  def handle_event("run_validate", %{"run" => params}, socket) do
    case socket.assigns.run_panel do
      nil -> {:noreply, socket}
      panel -> {:noreply, assign(socket, :run_panel, %{panel | task: params["task"] || ""})}
    end
  end

  def handle_event("run_submit", %{"run" => params}, socket) do
    if socket.assigns.run_panel && run_state(socket.assigns) == :enabled,
      do: {:noreply, submit_run(socket, params)},
      else: {:noreply, socket}
  end

  def handle_event("runs_more_pending", _params, socket),
    do: {:noreply, grow(socket, :pending_shown)}

  def handle_event("runs_more_history", _params, socket), do: {:noreply, grow(socket, :shown)}

  def handle_event(event, params, socket)
      when event in ~w(ask_cancel_run dismiss_cancel_run cancel_run retry_run),
      do: {:noreply, RunActions.handle_event(event, params, socket, &load_runs/1)}

  def handle_event("ask_disable", _params, socket),
    do: {:noreply, assign(socket, :confirm, :disable)}

  def handle_event("ask_archive", _params, socket),
    do: {:noreply, assign(socket, :confirm, :archive)}

  def handle_event("dismiss", _params, socket), do: {:noreply, assign(socket, :confirm, nil)}

  def handle_event("disable", _params, socket),
    do: act(socket, &Agents.disable/2, dgettext("ui", "已停用"))

  def handle_event("enable", _params, socket),
    do: act(socket, &Agents.enable/2, dgettext("ui", "已启用"))

  def handle_event("archive", _params, socket),
    do: act(socket, &Agents.archive/2, dgettext("ui", "已归档"))

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  defp act(socket, fun, message) do
    socket = assign(socket, :confirm, nil)

    case fun.(socket.assigns.current_scope, socket.assigns.name) do
      {:ok, view} ->
        {:noreply, socket |> put_agent(complete(socket, view)) |> put_flash(:info, message)}

      {:error, reason} ->
        {:noreply, socket |> reload() |> put_flash(:error, AgentForm.error_text(reason))}
    end
  end

  # The views returned by the agent functions lack the R7 fields RunData adds.
  defp complete(socket, view) do
    case RunData.agent(socket.assigns.current_scope, view.name) do
      {:ok, agent} -> agent
      _ -> view
    end
  end

  @impl true
  def handle_info(message, socket)
      when message in [{:agents_changed}, {:runtimes_changed}],
      do: {:noreply, Throttle.schedule(socket)}

  def handle_info({:run_updated, %{agent: name}}, %{assigns: %{name: name}} = socket),
    do: {:noreply, Throttle.schedule(socket, :reload_runs)}

  def handle_info(:reload_runs, socket),
    do: {:noreply, socket |> Throttle.done(:reload_runs) |> reload() |> load_runs()}

  def handle_info(%Phoenix.Socket.Broadcast{event: "presence_diff"}, socket),
    do: {:noreply, put_agent(socket, socket.assigns.agent)}

  def handle_info(:reload, socket), do: {:noreply, socket |> Throttle.done() |> reload()}
  def handle_info(_message, socket), do: {:noreply, socket}

  defp reload(socket) do
    case RunData.agent(socket.assigns.current_scope, socket.assigns.name) do
      {:ok, agent} ->
        socket = socket |> put_agent(agent) |> load_availability()

        case socket.assigns.agent_form do
          nil -> socket
          form -> assign(socket, :agent_form, AgentForm.refreshed(form, agent))
        end

      {:error, _} ->
        socket
    end
  end

  ## Rendering

  defp tab_path(uri, "runs"), do: Url.drop_params(uri, ["tab"])
  defp tab_path(uri, tab), do: Url.put_params(uri, %{tab: tab})

  defp access_text(agent, names) do
    member_names = Enum.map(agent.access_member_ids || [], &Map.get(names, &1, "#{&1}"))
    access_label(agent, member_names)
  end

  defp limits_text(agent),
    do:
      dgettext("ui", "%{total} 分钟 / %{idle} 分钟",
        total: agent.timeout_minutes,
        idle: agent.idle_timeout_minutes
      )

  defp confirm_title(:disable, name), do: dgettext("ui", "停用 %{name}？", name: name)
  defp confirm_title(:archive, name), do: dgettext("ui", "归档 %{name}？", name: name)
  defp confirm_title(_, _), do: ""

  defp confirm_text(:disable, name),
    do: dgettext("ui", "停用后 %{name} 不能再被触发，正在进行的运行会被停止，排队中的运行会被取消", name: name)

  defp confirm_text(:archive, name),
    do: dgettext("ui", "归档后 %{name} 只读且不可撤销，未结束的运行全部取消", name: name)

  defp confirm_text(_, _), do: ""

  defp actions(%{agent: agent, permissions: p}) do
    active? = agent.kind == "managed" and not agent.archived

    %{
      can_disable?: active? and p.administer and not agent.disabled,
      can_enable?: active? and p.configure and agent.disabled,
      can_archive?: active? and p.administer
    }
  end

  @impl true
  def render(assigns) do
    assigns =
      assigns
      |> assign(actions(assigns))
      |> assign(
        slug: assigns.current_scope.workspace.slug,
        managed?: assigns.agent.kind == "managed",
        can_edit?: can_edit?(assigns),
        edit_path: Url.put_params(assigns.uri || "", %{panel: "edit"}),
        run_path: Url.put_params(assigns.uri || "", %{panel: "run"}),
        run_state: run_state(assigns),
        close_path: Url.drop_params(assigns.uri || "", ["panel"])
      )

    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} shell={@shell}>
      <:header>
        <.page_header title={@agent.name}>
          <:crumb navigate={"/w/#{@slug}/agents"}>Agents</:crumb>
          <:actions>
            <.agent_status id="agent-status" status={@status} />
            <.button
              :if={@can_edit?}
              id="agent-edit"
              size="sm"
              icon="lucide-pencil"
              patch={@edit_path}
            >
              {dgettext("ui", "编辑")}
            </.button>
            <.button
              :if={@run_state != :hidden}
              id="agent-run"
              size="sm"
              variant="primary"
              icon="lucide-play"
              patch={@run_path}
              disabled_reason={match?({:disabled, _}, @run_state) && elem(@run_state, 1)}
            >
              {dgettext("ui", "运行")}
            </.button>
            <.button :if={@can_enable?} id="agent-enable" size="sm" phx-click="enable">
              {dgettext("ui", "启用")}
            </.button>
            <.dropdown
              :if={@can_disable? or @can_archive?}
              id="agent-more"
              label={dgettext("ui", "更多操作")}
              align={:end}
              trigger_class="h-8 w-8 justify-center"
              items={
                Enum.reject(
                  [
                    @can_disable? &&
                      %{
                        id: "agent-disable",
                        label: dgettext("ui", "停用"),
                        icon: "lucide-circle-pause",
                        on_select: "ask_disable"
                      },
                    @can_archive? &&
                      %{
                        id: "agent-archive",
                        label: dgettext("ui", "归档"),
                        icon: "lucide-archive",
                        danger: true,
                        on_select: "ask_archive"
                      }
                  ],
                  &(&1 == false)
                )
              }
            >
              <:trigger><.icon name="lucide-ellipsis" class="size-4" /></:trigger>
            </.dropdown>
          </:actions>
        </.page_header>
      </:header>

      <div :if={!@managed?} id="agent-external" class="mx-auto w-full max-w-2xl px-4 py-6">
        <div class="rounded-box border border-border bg-surface p-4">
          <.property_list>
            <.property_row label={dgettext("ui", "所属用户")} value={@agent.owner.name} />
            <.property_row label={dgettext("ui", "类型")} value={dgettext("ui", "外接")} />
            <.property_row label={dgettext("ui", "在线状态")}>
              <.presence_dot status={if(@online?, do: :online, else: :offline)} />
              <span class="text-fg">
                {if(@online?, do: dgettext("ui", "在线"), else: dgettext("ui", "离线"))}
              </span>
            </.property_row>
          </.property_list>
          <p class="mt-4 text-body text-fg-muted">
            {dgettext("ui", "外接 Agent 由人自己启动的 CLI 通过 MCP 接入，Helmsman 不派发运行")}
          </p>
        </div>
      </div>

      <div
        :if={@managed?}
        id="agent-layout"
        class="grid gap-6 px-4 py-4 lg:grid-cols-[minmax(0,1fr)_320px] lg:px-6"
      >
        <section class="flex min-w-0 flex-col gap-4">
          <.tabs label={dgettext("ui", "Agent 内容")}>
            <:tab patch={tab_path(@uri || "", "runs")} active={@tab == "runs"}>
              {dgettext("ui", "运行")}
            </:tab>
            <:tab patch={tab_path(@uri || "", "instructions")} active={@tab == "instructions"}>
              {dgettext("ui", "指令")}
            </:tab>
            <:tab patch={tab_path(@uri || "", "usage")} active={@tab == "usage"}>
              {dgettext("ui", "用量")}
            </:tab>
          </.tabs>

          <.runs_tab
            :if={@tab == "runs"}
            runs={@runs}
            stream={@streams.agent_runs}
            scope={@current_scope}
          />

          <div :if={@tab == "instructions"} id="agent-instructions">
            <.markdown
              :if={String.trim(@agent.instructions || "") != ""}
              content={@agent.instructions}
              scope={@current_scope}
              anchor_ns="agent-instructions"
            />
            <p
              :if={String.trim(@agent.instructions || "") == ""}
              class="py-6 text-center text-body text-fg-muted"
            >
              {dgettext("ui", "没有指令")}
            </p>
          </div>

          <div :if={@tab == "usage"} id="agent-usage">
            <p class="py-6 text-center text-body text-fg-muted">{dgettext("ui", "近 30 天没有运行")}</p>
          </div>
        </section>

        <aside id="agent-properties" aria-label={dgettext("ui", "属性")}>
          <.property_list>
            <.property_row label={dgettext("ui", "所属用户")} value={@agent.owner.name} data-owner />
            <.property_row label="CLI" data-provider-row>
              <.provider provider={@agent.provider} />
            </.property_row>
            <.property_row label={dgettext("ui", "运行时")} data-runtime-row>
              <.link
                :if={@agent.runtime}
                navigate={"/w/#{@slug}/settings/runtimes"}
                class="flex min-w-0 items-center gap-1.5 text-fg hover:underline"
              >
                <.presence_dot status={
                  if(@agent.runtime.status == "online" and !@agent.runtime.disabled,
                    do: :online,
                    else: :offline
                  )
                } />
                <span class="truncate">{@agent.runtime.daemon_name}</span>
              </.link>
              <span :if={!@agent.runtime} class="text-fg-subtle">{dgettext("ui", "未绑定运行时")}</span>
            </.property_row>
            <.property_row
              label={dgettext("ui", "模型")}
              value={@agent.model || dgettext("ui", "CLI 缺省")}
              data-model
            />
            <.property_row
              label={dgettext("ui", "推理强度")}
              value={@agent.effort || dgettext("ui", "CLI 缺省")}
              data-effort
            />
            <.property_row
              label={dgettext("ui", "谁能触发")}
              value={access_text(@agent, @member_names)}
              data-access
            />
            <.property_row
              label={dgettext("ui", "额外能力")}
              value={if("create_tasks" in (@agent.capabilities || []), do: dgettext("ui", "允许创建任务"))}
            />
            <.property_row
              label={dgettext("ui", "并发上限")}
              value={to_string(@agent.max_concurrency)}
              data-max-concurrency
            />
            <.property_row label={dgettext("ui", "总时长 / 无输出")} value={limits_text(@agent)} />
            <.property_row
              label={dgettext("ui", "追加参数")}
              value={Enum.join(@agent.custom_args || [], " ")}
            />
            <.property_row label={dgettext("ui", "环境变量")} data-env-names>
              <span :if={(@agent.env_names || []) != []} class="flex flex-wrap gap-1">
                <code :for={n <- @agent.env_names} class="font-mono text-label text-fg">{n}</code>
              </span>
            </.property_row>
            <.property_row label={dgettext("ui", "MCP 服务器")} data-mcp-names>
              <span :if={(@agent.extra_mcp_server_names || []) != []} class="flex flex-wrap gap-1">
                <code :for={n <- @agent.extra_mcp_server_names} class="font-mono text-label text-fg">
                  {n}
                </code>
              </span>
            </.property_row>
            <.property_row label={dgettext("ui", "描述")} value={@agent.description} data-description />
            <.property_row :if={@agent.inserted_at} label={dgettext("ui", "创建时间")}>
              <.relative_time id="agent-created" at={@agent.inserted_at} class="text-fg" />
            </.property_row>
          </.property_list>
        </aside>
      </div>

      <AgentForm.panel
        :if={@can_edit? or @agent_form}
        form={@agent_form}
        scope={@current_scope}
        close_path={@close_path}
      />

      <.run_panel panel={@run_panel} scope={@current_scope} close_path={@close_path} />
      <RunActions.dialog stop_run={@stop_run} />

      <.confirm_dialog
        id="agent-confirm"
        show={@confirm != nil}
        title={confirm_title(@confirm, @agent.name)}
        danger
        confirm_label={if(@confirm == :archive, do: dgettext("ui", "归档"), else: dgettext("ui", "停用"))}
        on_confirm={if(@confirm == :archive, do: "archive", else: "disable")}
        on_cancel={JS.push("dismiss")}
      >
        {confirm_text(@confirm, @agent.name)}
      </.confirm_dialog>
    </Layouts.app>
    """
  end

  attr :runs, :map, required: true
  attr :stream, :any, required: true
  attr :scope, :map, required: true

  defp runs_tab(assigns) do
    runs = assigns.runs

    assigns =
      assign(assigns,
        slug: assigns.scope.workspace.slug,
        more_pending: runs.pending_total - length(runs.pending),
        empty?: runs.active == [] and runs.pending == [] and runs.total == 0
      )

    ~H"""
    <div id="agent-runs" class="flex flex-col gap-4">
      <p :if={@empty?} id="agent-runs-empty" class="py-6 text-center text-body text-fg-muted">
        {dgettext("ui", "还没有运行")}
      </p>
      <div
        :if={@runs.active != [] or @runs.pending != []}
        id="agent-runs-open"
        class="flex flex-col gap-2"
      >
        <.run_card
          :for={run <- @runs.active ++ @runs.pending}
          id={"run-card-#{run.id}"}
          run={run}
          scope={@scope}
          can_cancel={cancellable?(@scope, run)}
        />
        <.button
          :if={@more_pending > 0}
          id="agent-runs-more-pending"
          size="sm"
          variant="ghost"
          phx-click="runs_more_pending"
        >
          {dgettext("ui", "还有 %{n} 条排队中", n: @more_pending)}
        </.button>
      </div>
      <section
        :if={@runs.total > 0}
        id="agent-runs-history"
        aria-labelledby="agent-runs-history-title"
      >
        <h2 id="agent-runs-history-title" class="mb-1 text-label font-medium text-fg-muted">
          {dgettext("ui", "已结束")} <span data-total>{@runs.total}</span>
        </h2>
        <.data_table
          id="agent-run-rows"
          rows={@stream}
          label={dgettext("ui", "已结束的运行")}
          row_click={&JS.navigate("/w/#{@slug}/runs/#{&1.id}")}
          has_more={@runs.shown < @runs.total}
          load_more="runs_more_history"
        >
          <:col :let={r} label={dgettext("ui", "运行")} class="w-20">
            <span class="font-mono text-caption text-fg-muted">#{r.id}</span>
          </:col>
          <:col :let={r} label={dgettext("ui", "任务")} class="w-24">
            <.task_id_link :if={r.task} ident={r.task} workspace={@slug} />
          </:col>
          <:col :let={r} label={dgettext("ui", "状态")} class="w-28">
            <.run_status_badge status={r.status} />
          </:col>
          <:col :let={r} label={dgettext("ui", "触发")} secondary>
            <span class="truncate text-fg-muted">{trigger_summary(r.triggers)}</span>
          </:col>
          <:col :let={r} label={dgettext("ui", "开始时间")} class="w-28" secondary>
            <.relative_time
              :if={r[:started_at] || r[:claimed_at]}
              id={"run-row-#{r.id}-started"}
              at={r[:started_at] || r[:claimed_at]}
              class="text-fg-muted"
            />
          </:col>
          <:col :let={r} label={dgettext("ui", "耗时")} class="w-24" secondary>
            <span class="text-fg-muted">{duration_text(r)}</span>
          </:col>
        </.data_table>
      </section>
    </div>
    """
  end

  attr :panel, :map, default: nil
  attr :scope, :map, required: true
  attr :close_path, :string, required: true

  defp run_panel(assigns) do
    ~H"""
    <.side_panel
      id="run-panel"
      show={@panel != nil}
      title={dgettext("ui", "手动运行")}
      dirty={@panel != nil}
      patch_on_close={@close_path}
    >
      <:error :if={@panel && @panel.error}>{@panel.error}</:error>
      <.form
        :if={@panel}
        for={%{}}
        as={:run}
        id="run-form"
        phx-change="run_validate"
        phx-submit="run_submit"
        class="flex flex-col gap-4"
      >
        <.input
          id="run-task"
          name="run[task]"
          label={dgettext("ui", "任务（可选）")}
          placeholder="BOS-3"
          value={@panel.task}
          autocomplete="off"
          errors={Map.get(@panel.errors, :task, [])}
        />
        <.live_component
          module={MarkdownEditor}
          id={"run-instructions-#{@panel.gen}"}
          session={@panel.gen}
          scope={@scope}
          name="run[instructions]"
          value=""
          label={dgettext("ui", "说明")}
          errors={Map.get(@panel.errors, :instructions, [])}
          submit={:form}
          rows={6}
        />
      </.form>
      <:footer :let={cancel}>
        <span />
        <div class="flex items-center gap-2">
          <.button phx-click={cancel}>{dgettext("ui", "取消")}</.button>
          <.button id="run-submit" type="submit" form="run-form" variant="primary">
            {dgettext("ui", "运行")}
          </.button>
        </div>
      </:footer>
    </.side_panel>
    """
  end
end
