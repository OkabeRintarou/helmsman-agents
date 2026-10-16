defmodule HelmsmanWeb.UserLive.McpServers do
  @moduledoc "Personal MCP definitions, available only in the authenticated user's web session."
  use HelmsmanWeb, :live_view
  alias Helmsman.{Events, McpServers}
  alias HelmsmanWeb.{AvatarData, FormErrors, McpEditor}

  @impl true
  def mount(_, _, socket) do
    scope = socket.assigns.current_scope
    if connected?(socket), do: Events.subscribe("user_mcp_servers:#{scope.user.id}")

    {:ok,
     socket
     |> assign(
       page_title: dgettext("ui", "我的 MCP 服务器"),
       avatar: AvatarData.user_avatar(scope.user),
       editor: nil,
       gen: 0,
       confirm: nil,
       errors: [],
       name_errors: []
     )
     |> load()}
  end

  defp load(socket) do
    {:ok, definitions} = McpServers.list(socket.assigns.current_scope)
    assign(socket, :definitions, definitions)
  end

  @impl true
  def handle_params(params, _, socket) do
    case params["panel"] do
      "new" ->
        {:noreply,
         assign(socket,
           editor: %{id: nil, name: "", original_name: "", config: %{}},
           gen: socket.assigns.gen + 1,
           errors: [],
           name_errors: []
         )}

      "edit" ->
        scope = socket.assigns.current_scope

        with {:ok, d} <- McpServers.get(scope, params["id"]),
             {:ok, config} <- McpServers.editable(scope, d.id) do
          {:noreply,
           assign(socket,
             editor: %{id: d.id, name: d.name, original_name: d.name, config: %{d.name => config}},
             gen: socket.assigns.gen + 1,
             errors: [],
             name_errors: []
           )}
        else
          _ ->
            {:noreply,
             socket
             |> put_flash(:error, dgettext("ui", "定义不存在"))
             |> push_patch(to: ~p"/users/settings/mcp-servers")}
        end

      _ ->
        {:noreply, assign(socket, :editor, nil)}
    end
  end

  @impl true
  def handle_event("mcp_validate", params, socket),
    do: {:reply, HelmsmanWeb.McpEditor.validate_reply(params), socket}

  def handle_event("mcp_import", params, socket),
    do: {:reply, McpEditor.import_reply(params), socket}

  def handle_event("save", %{"definition" => params}, socket) do
    editor = socket.assigns.editor
    scope = socket.assigns.current_scope
    result = save_definition(scope, editor, params)

    case result do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(editor: nil, errors: [])
         |> load()
         |> put_flash(:info, dgettext("ui", "已保存"))
         |> push_patch(to: ~p"/users/settings/mcp-servers")}

      {:error, %Ecto.Changeset{} = cs} ->
        messages = FormErrors.messages(cs)

        {:noreply,
         assign(socket,
           editor: %{editor | name: params["name"] || editor.name},
           name_errors: Map.get(messages, :name, []),
           errors: messages |> Map.delete(:name) |> Map.values() |> List.flatten()
         )}

      {:error, :limit_reached} ->
        {:noreply, assign(socket, :errors, [dgettext("ui", "最多 32 个个人定义")])}

      _ ->
        {:noreply, assign(socket, :errors, [dgettext("ui", "请填写一个有效的 MCP 服务器条目")])}
    end
  end

  def handle_event("ask_delete", %{"id" => id}, socket) do
    case McpServers.get(socket.assigns.current_scope, id) do
      {:ok, d} -> {:noreply, assign(socket, :confirm, d)}
      _ -> {:noreply, socket}
    end
  end

  def handle_event("cancel_delete", _, socket), do: {:noreply, assign(socket, :confirm, nil)}
  def handle_event("delete", _, %{assigns: %{confirm: nil}} = socket), do: {:noreply, socket}

  def handle_event("delete", _, socket) do
    case McpServers.delete(socket.assigns.current_scope, socket.assigns.confirm.id) do
      {:ok, _} ->
        {:noreply,
         socket |> assign(:confirm, nil) |> load() |> put_flash(:info, dgettext("ui", "已删除"))}

      {:error, {:in_use, agents}} ->
        {:noreply,
         socket
         |> assign(:confirm, nil)
         |> put_flash(
           :error,
           dgettext("ui", "请先取消这些 Agent 的引用：%{agents}",
             agents: Enum.map_join(agents, ", ", &"#{&1.workspace_slug}/#{&1.name}")
           )
         )}

      _ ->
        {:noreply, assign(socket, :confirm, nil)}
    end
  end

  defp save_definition(scope, editor, params) do
    decoded =
      if (params["mcp"] || "") == "", do: {:ok, editor.config}, else: Jason.decode(params["mcp"])

    case decoded do
      {:ok, values} when is_map(values) and map_size(values) == 1 ->
        [{server_name, value}] = Map.to_list(values)
        name = definition_name(editor, params, server_name)
        attrs = %{name: name, config: value}

        if editor.id,
          do: McpServers.update(scope, editor.id, attrs),
          else: McpServers.create(scope, attrs)

      _ ->
        {:error, :invalid_json}
    end
  end

  defp definition_name(editor, params, server_name) do
    name = String.trim(params["name"] || "")

    if name != "" and (server_name == editor.original_name or editor.id == nil),
      do: name,
      else: server_name
  end

  @impl true
  def handle_info({:mcp_servers_changed}, socket), do: {:noreply, load(socket)}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.personal
      flash={@flash}
      current_scope={@current_scope}
      avatar={@avatar}
      active={:mcp_servers}
    >
      <div class="flex flex-col gap-4 p-4">
        <div class="flex items-center justify-between">
          <h2 class="text-heading font-semibold">{dgettext("ui", "我的 MCP 服务器")}</h2><.link
            patch={~p"/users/settings/mcp-servers?panel=new"}
            class="text-label text-brand"
          >{dgettext("ui", "添加")}</.link>
        </div>
        <p class="text-body text-fg-muted">
          {dgettext("ui", "这些服务器只给你自己的 Agent 用，在你的 Agent 所在的机器上运行；密钥建议用本机变量。")}
        </p>
        <p :if={@definitions == []} class="text-body text-fg-muted">
          {dgettext("ui", "还没有 MCP 服务器")}
        </p>
        <div
          :for={d <- @definitions}
          id={"mcp-definition-#{d.id}"}
          class="flex flex-col gap-2 rounded-card border border-border p-4"
        >
          <McpEditor.summaries summaries={[d.summary]} />
          <p class="text-caption text-fg-muted">
            {dgettext("ui", "被 %{n} 个 Agent 使用", n: length(d.agents))}
          </p>
          <.link
            :for={a <- d.agents}
            navigate={"/w/#{a.workspace_slug}/agents/#{a.name}"}
            class="text-caption text-brand"
          >{a.workspace_slug}/{a.name}</.link>
          <div class="flex gap-3">
            <.link
              patch={~p"/users/settings/mcp-servers?panel=edit&id=#{d.id}"}
              class="text-label text-brand"
            >{dgettext("ui", "编辑")}</.link><button
              type="button"
              phx-click="ask_delete"
              phx-value-id={d.id}
              class="text-label text-danger"
            >{dgettext("ui", "删除")}</button>
          </div>
        </div>
        <.side_panel
          id="mcp-definition-panel"
          show={@editor != nil}
          title={dgettext("ui", "MCP 服务器")}
          width={:wide}
          patch_on_close={~p"/users/settings/mcp-servers"}
        >
          <.form
            :if={@editor}
            for={to_form(%{}, as: :definition)}
            id="mcp-definition-form"
            phx-submit="save"
            class="flex min-w-0 w-full flex-col gap-3 rounded-card border border-border p-4"
          >
            <.input
              name="definition[name]"
              value={@editor.name}
              label={dgettext("ui", "名字")}
              errors={@name_errors}
            />
            <McpEditor.editor
              id={"definition-editor-#{@gen}"}
              config={@editor.config}
              name="definition[mcp]"
              single
            />
            <p :for={e <- @errors} class="text-caption text-danger">{e}</p>
            <div class="flex gap-3">
              <.button type="submit">{dgettext("ui", "保存")}</.button><.link patch={
                ~p"/users/settings/mcp-servers"
              }>{dgettext("ui", "取消")}</.link>
            </div>
          </.form>
        </.side_panel>
        <.confirm_dialog
          id="delete-mcp-definition"
          show={@confirm != nil}
          title={dgettext("ui", "删除 MCP 服务器？")}
          confirm_label={dgettext("ui", "删除")}
          on_confirm={JS.push("delete")}
          on_cancel={JS.push("cancel_delete")}
        />
      </div>
    </Layouts.personal>
    """
  end
end
