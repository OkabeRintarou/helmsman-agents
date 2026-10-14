defmodule HelmsmanWeb.AgentLive.Index do
  @moduledoc """
  `/w/:slug/agents` (spec web-agents Agent 列表页, design D3, D4): every agent of the
  workspace with its status, `?owner=me`, `?archived=1` and the new-agent panel
  (`?panel=new-agent`; `?panel=new` is the shell's 新建任务).

  Subscribes to the workspace's runs and the agents' presence before reading (D9a);
  `{:agents_changed}`, `{:runtimes_changed}` (forwarded by the shell) and
  `{:run_updated, _}` reload the list through `HelmsmanWeb.Throttle`. The current user's
  `{:provider_accounts_changed}` reloads the account options of an open panel.
  """
  use HelmsmanWeb, :live_view

  import HelmsmanWeb.AgentComponents

  alias Helmsman.{Events, Policy, Presence, ProviderAccounts}
  alias HelmsmanWeb.{AgentForm, RunData, Throttle, Url}

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope

    if connected?(socket) do
      Events.subscribe(Events.topic(:workspace_runs, scope.workspace.id))
      Events.subscribe(Presence.agents_topic(scope.workspace.id))
      Events.subscribe(ProviderAccounts.topic(scope.user.id))
    end

    {:ok,
     socket
     |> assign(
       page_title: "Agents",
       can_create?: Policy.authorize(scope, :manage_agents) == :ok,
       mine?: false,
       archived?: false,
       agents: [],
       online: MapSet.new(),
       uri: nil,
       agent_form: nil,
       form_gen: 0,
       empty?: true,
       shown?: false
     )
     |> stream_configure(:agents, dom_id: &"agent-#{dom_key(&1.name)}")
     |> stream(:agents, [])
     |> load_online()
     |> load()}
  end

  @doc "A DOM-id-safe, injective form of an agent name (`keel/dev` → `keel_2fdev`)."
  def dom_key(name),
    do:
      String.replace(name, ~r/[^a-z0-9-]/, fn <<c>> ->
        "_" <> Base.encode16(<<c>>, case: :lower)
      end)

  @impl true
  def handle_params(params, uri, socket) do
    %URI{path: path, query: query} = URI.parse(uri)

    socket =
      socket
      |> assign(
        uri: if(query, do: "#{path}?#{query}", else: path),
        mine?: params["owner"] == "me",
        archived?: params["archived"] == "1"
      )
      |> render_rows()

    {:noreply, open_form(socket, params["panel"] == "new-agent" and socket.assigns.can_create?)}
  end

  defp open_form(socket, false), do: assign(socket, :agent_form, nil)
  defp open_form(%{assigns: %{agent_form: %{}}} = socket, true), do: socket

  defp open_form(socket, true) do
    gen = socket.assigns.form_gen + 1

    socket
    |> assign(:form_gen, gen)
    |> assign(:agent_form, AgentForm.new(socket.assigns.current_scope, gen))
  end

  defp load(socket) do
    agents =
      case RunData.agents(socket.assigns.current_scope) do
        {:ok, agents} -> agents
        {:error, _} -> []
      end

    socket |> assign(:agents, agents) |> render_rows()
  end

  defp load_online(socket) do
    topic = Presence.agents_topic(socket.assigns.current_scope.workspace.id)

    online =
      for {_key, %{metas: metas}} <- Presence.list(topic),
          %{actor_name: name} <- metas,
          is_binary(name),
          into: MapSet.new(),
          do: name

    assign(socket, :online, online)
  end

  defp render_rows(socket) do
    %{agents: agents, mine?: mine?, archived?: archived?, current_scope: scope} = socket.assigns

    rows =
      agents
      |> Enum.filter(
        &((archived? or not &1.archived) and (not mine? or &1.owner.id == scope.user.id))
      )
      |> Enum.map(&Map.put(&1, :status, status(&1, socket.assigns.online)))

    socket
    |> assign(empty?: agents == [], shown?: rows != [])
    |> stream(:agents, rows, reset: true)
  end

  @impl true
  def handle_event("agent_form_" <> _ = event, params, socket) do
    case AgentForm.handle_event(event, params, socket) do
      {:saved, view, socket} ->
        path = Url.agent_path(socket.assigns.current_scope.workspace.slug, view.name)

        {:noreply,
         socket
         |> put_flash(:info, dgettext("ui", "已创建 %{name}", name: view.name))
         |> push_navigate(to: path)}

      result ->
        result
    end
  end

  @impl true
  def handle_info(message, socket)
      when message in [{:agents_changed}, {:runtimes_changed}],
      do: {:noreply, Throttle.schedule(socket)}

  def handle_info({:run_updated, _summary}, socket), do: {:noreply, Throttle.schedule(socket)}

  def handle_info({:provider_accounts_changed}, %{assigns: %{agent_form: %{} = form}} = socket),
    do:
      {:noreply,
       assign(
         socket,
         :agent_form,
         AgentForm.accounts_changed(form, socket.assigns.current_scope)
       )}

  def handle_info(%Phoenix.Socket.Broadcast{event: "presence_diff"}, socket),
    do: {:noreply, socket |> load_online() |> render_rows()}

  # The shell reloaded `@appearance`; the streamed rows are rendered again.
  def handle_info({:avatars_changed}, socket), do: {:noreply, render_rows(socket)}

  def handle_info(:reload, socket), do: {:noreply, socket |> Throttle.done() |> load()}
  def handle_info(_message, socket), do: {:noreply, socket}

  defp toggle_path(uri, key, true, value), do: Url.put_params(uri, %{key => value})
  defp toggle_path(uri, key, false, _value), do: Url.drop_params(uri, [key])

  defp kind_label("managed"), do: dgettext("ui", "托管")
  defp kind_label(_), do: dgettext("ui", "外接")

  defp chip_actor(a, appearance),
    do:
      Appearance.decorate(
        %{name: a.name, kind: :agent, managed?: a.kind == "managed", owner_name: a.owner.name},
        appearance
      )

  @impl true
  def render(assigns) do
    assigns =
      assign(assigns,
        slug: assigns.current_scope.workspace.slug,
        new_path: Url.put_params(assigns.uri || "", %{panel: "new-agent"}),
        close_path: Url.drop_params(assigns.uri || "", ["panel"])
      )

    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} shell={@shell}>
      <:header>
        <.page_header title="Agents">
          <:actions>
            <nav id="agents-owner" class="flex gap-1" aria-label={dgettext("ui", "范围")}>
              <.link
                id="agents-all"
                patch={toggle_path(@uri || "", "owner", false, nil)}
                aria-current={!@mine? && "page"}
                class={[
                  "rounded-field px-2 py-1 text-body",
                  if(@mine?, do: "text-fg-muted hover:bg-hover", else: "bg-selected text-fg")
                ]}
              >
                {dgettext("ui", "全部")}
              </.link>
              <.link
                id="agents-mine"
                patch={toggle_path(@uri || "", "owner", true, "me")}
                aria-current={@mine? && "page"}
                class={[
                  "rounded-field px-2 py-1 text-body",
                  if(@mine?, do: "bg-selected text-fg", else: "text-fg-muted hover:bg-hover")
                ]}
              >
                {dgettext("ui", "我的")}
              </.link>
            </nav>
            <.link
              id="agents-archived"
              patch={toggle_path(@uri || "", "archived", !@archived?, "1")}
              role="switch"
              aria-checked={to_string(@archived?)}
              class="inline-flex items-center gap-1.5 rounded-field px-2 py-1 text-body text-fg-muted hover:bg-hover"
            >
              <.icon
                name={if(@archived?, do: "lucide-square-check", else: "lucide-square")}
                class="size-4"
              />
              {dgettext("ui", "显示已归档")}
            </.link>
            <.button
              :if={@can_create?}
              id="agents-design"
              size="sm"
              icon="lucide-messages-square"
              navigate={Url.agent_design_path(@current_scope.workspace.slug)}
            >
              {dgettext("ui", "用对话创建")}
            </.button>
            <.button
              :if={@can_create?}
              id="agents-new"
              variant="primary"
              size="sm"
              icon="lucide-plus"
              patch={@new_path}
            >
              {dgettext("ui", "新建 Agent")}
            </.button>
          </:actions>
        </.page_header>
      </:header>

      <div class="px-4 py-4 lg:px-6">
        <div :if={@empty?} id="agents-empty">
          <.empty_state
            icon="lucide-bot"
            title={dgettext("ui", "还没有 Agent")}
            description={
              dgettext(
                "ui",
                "托管 Agent 由你的守护进程在本机运行 CLI，可被指派任务并自动开始；外接 Agent 是你自己启动的 CLI 通过 MCP 接入。"
              )
            }
          >
            <:action :if={@can_create?}>
              <.button variant="primary" size="sm" icon="lucide-plus" patch={@new_path}>
                {dgettext("ui", "新建 Agent")}
              </.button>
            </:action>
          </.empty_state>
        </div>

        <p
          :if={!@empty? and !@shown?}
          id="agents-none"
          class="py-6 text-center text-body text-fg-muted"
        >
          {dgettext("ui", "没有符合条件的 Agent")}
        </p>

        <.data_table
          :if={!@empty?}
          id="agents"
          rows={@streams.agents}
          label="Agents"
          rich
          row_click={&JS.navigate(Url.agent_path(@slug, &1.name))}
        >
          <:col :let={a} label="Agent" class="w-[24%]">
            <.link navigate={Url.agent_path(@slug, a.name)} class="min-w-0" data-agent-link>
              <.actor_chip actor={chip_actor(a, @appearance)} presence={presence(a.status)} />
            </.link>
          </:col>
          <:col :let={a} label={dgettext("ui", "状态")}>
            <.agent_status status={a.status} />
          </:col>
          <:col :let={a} label={dgettext("ui", "所属用户")} secondary>
            <span class="truncate text-fg-muted" data-owner>{a.owner.name}</span>
          </:col>
          <:col :let={a} label={dgettext("ui", "类型")} secondary>
            <span class="text-fg-muted" data-kind>{kind_label(a.kind)}</span>
          </:col>
          <:col :let={a} label={dgettext("ui", "CLI 与机器")} class="w-[22%]">
            <span :if={a.kind == "managed"} class="flex min-w-0 items-center gap-2" data-cli>
              <.provider provider={a.provider} />
              <span :if={a.runtime} class="truncate text-fg-muted">{a.runtime.daemon_name}</span>
              <span :if={!a.runtime} class="truncate text-fg-subtle">
                {dgettext("ui", "未绑定运行时")}
              </span>
            </span>
          </:col>
          <:col :let={a} label={dgettext("ui", "排队")} class="w-20" secondary>
            <span :if={(a[:queued_runs] || 0) > 0} class="text-fg-muted" data-queued>
              {a.queued_runs}
            </span>
          </:col>
          <:col :let={a} label={dgettext("ui", "最近运行")} class="w-28" secondary>
            <.relative_time
              :if={a.last_run_at}
              id={"agent-#{dom_key(a.name)}-last-run"}
              at={a.last_run_at}
              class="text-fg-muted"
            />
          </:col>
        </.data_table>
      </div>

      <AgentForm.panel
        :if={@can_create?}
        form={@agent_form}
        scope={@current_scope}
        close_path={@close_path}
      />
    </Layouts.app>
    """
  end
end
