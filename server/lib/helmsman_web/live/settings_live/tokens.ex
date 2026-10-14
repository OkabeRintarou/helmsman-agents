defmodule HelmsmanWeb.SettingsLive.Tokens do
  @moduledoc """
  API token settings `/w/:slug/settings/tokens` (spec web-workspace-settings 我的 Token /
  新建 Token / 工作区全部 Token, design D6, D7): the user's own tokens, the new-token
  panel (`?panel=new-token`; `?panel=new` is the shell's 新建任务) and, for admins and
  above, every token of the workspace.

  The plaintext token exists only in `@token_result` while the panel shows it.
  """
  use HelmsmanWeb, :live_view

  import HelmsmanWeb.SettingsComponents

  alias Helmsman.{Actors, ApiTokens, Policy}
  alias Helmsman.ApiTokens.ApiToken
  alias HelmsmanWeb.{FormErrors, Url}
  alias HelmsmanWeb.SettingsLive.Errors

  @expiry_options ~w(never 30 90 365)
  @default_params %{
    "name" => "",
    "scopes" => ["mcp"],
    "expires_in" => "90",
    "default_agent_id" => ""
  }

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope

    {:ok,
     socket
     |> assign(
       page_title: dgettext("ui", "API Token"),
       can_create?: Policy.authorize(scope, :create_token) == :ok,
       can_list_all?: Policy.authorize(scope, :list_all_tokens) == :ok,
       agents: Actors.list_own_agents(scope),
       tokens: %{},
       confirm: nil,
       form: nil,
       token_result: nil,
       uri: nil
     )
     |> stream_configure(:own, dom_id: &"own-token-#{&1.id}")
     |> stream_configure(:all, dom_id: &"all-token-#{&1.id}")
     |> load()}
  end

  @impl true
  def handle_params(params, uri, socket) do
    %URI{path: path, query: query} = URI.parse(uri)
    open? = params["panel"] == "new-token" and socket.assigns.can_create?

    form =
      cond do
        not open? -> nil
        socket.assigns.form -> socket.assigns.form
        true -> new_form()
      end

    {:noreply,
     assign(socket,
       uri: if(query, do: "#{path}?#{query}", else: path),
       form: form,
       token_result: if(open?, do: socket.assigns.token_result)
     )}
  end

  defp new_form, do: %{params: @default_params, errors: %{}}

  # The shell reloaded `@appearance` (a runtime's vendor too, update-actor-icons D13): the
  # streamed rows show the default Agents' marks.
  @impl true
  def handle_info(message, socket) when message in [{:avatars_changed}, {:runtimes_changed}],
    do: {:noreply, load(socket)}

  def handle_info(_message, socket), do: {:noreply, socket}

  defp load(socket) do
    scope = socket.assigns.current_scope

    own =
      case ApiTokens.list_own(scope) do
        {:ok, tokens} -> tokens
        {:error, _} -> []
      end

    all =
      with true <- socket.assigns.can_list_all?,
           {:ok, tokens} <- ApiTokens.list_all(scope) do
        tokens
      else
        _ -> []
      end

    socket
    |> assign(tokens: Map.new(own ++ all, &{&1.id, &1}), own_empty?: own == [])
    |> stream(:own, own, reset: true)
    |> stream(:all, all, reset: true)
  end

  @impl true
  def handle_event("validate", %{"token" => params}, %{assigns: %{form: %{}}} = socket) do
    {:noreply, assign(socket, :form, %{socket.assigns.form | params: form_params(params)})}
  end

  def handle_event("create", %{"token" => params}, %{assigns: %{form: %{}}} = socket) do
    params = form_params(params)

    case ApiTokens.create(socket.assigns.current_scope, attrs(params)) do
      {:ok, %{token: token, api_token: api_token}} ->
        result = %{token: token, mcp?: "mcp" in api_token.scopes}

        {:noreply,
         socket
         |> assign(form: new_form(), token_result: result)
         |> load()}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         assign(socket, :form, %{params: params, errors: FormErrors.messages(changeset)})}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:form, %{params: params, errors: %{}})
         |> put_flash(:error, Errors.message(reason))}
    end
  end

  def handle_event(event, _params, socket) when event in ~w(validate create),
    do: {:noreply, socket}

  def handle_event("ask_revoke", %{"id" => id}, socket) do
    case fetch(socket.assigns.tokens, id) do
      {:ok, token} -> {:noreply, assign(socket, :confirm, %{id: token.id, name: token.name})}
      :error -> {:noreply, socket}
    end
  end

  def handle_event("dismiss", _params, socket), do: {:noreply, assign(socket, :confirm, nil)}

  def handle_event("revoke", %{"id" => id}, socket) do
    case fetch(socket.assigns.tokens, id) do
      {:ok, token} -> {:noreply, revoke(socket, token)}
      :error -> {:noreply, socket}
    end
  end

  defp revoke(socket, token) do
    case ApiTokens.revoke(socket.assigns.current_scope, token.id) do
      {:ok, %ApiToken{revoked_at: revoked_at}} ->
        token = %{token | revoked_at: revoked_at}

        socket
        |> assign(confirm: nil, tokens: Map.put(socket.assigns.tokens, token.id, token))
        |> insert_revoked(token)
        |> put_flash(:info, dgettext("ui", "Token 已吊销"))

      {:error, reason} ->
        socket = socket |> assign(:confirm, nil) |> put_flash(:error, Errors.message(reason))
        if Errors.reload?(reason), do: load(socket), else: socket
    end
  end

  # Updates the row in both tables (its preloads are kept from the listing).
  defp insert_revoked(socket, token) do
    socket =
      if token.user_id == socket.assigns.current_scope.user.id,
        do: stream_insert(socket, :own, token),
        else: socket

    if socket.assigns.can_list_all?, do: stream_insert(socket, :all, token), else: socket
  end

  defp fetch(map, id) do
    case Integer.parse(to_string(id)) do
      {id, ""} -> Map.fetch(map, id)
      _ -> :error
    end
  end

  defp form_params(params) do
    %{
      "name" => Map.get(params, "name", ""),
      "scopes" =>
        params |> Map.get("scopes", []) |> List.wrap() |> Enum.filter(&(&1 in ApiToken.scopes())),
      "expires_in" =>
        if(params["expires_in"] in @expiry_options, do: params["expires_in"], else: "90"),
      "default_agent_id" => Map.get(params, "default_agent_id", "")
    }
  end

  defp attrs(params) do
    %{
      "name" => params["name"],
      "scopes" => params["scopes"],
      "expires_at" => expires_at(params["expires_in"]),
      "default_agent_id" =>
        if(params["default_agent_id"] in [nil, ""], do: nil, else: params["default_agent_id"])
    }
  end

  defp expires_at("never"), do: nil

  defp expires_at(days) do
    DateTime.add(DateTime.utc_now(:second), String.to_integer(days), :day)
  end

  @doc false
  def mcp_command(token) do
    url = HelmsmanWeb.Endpoint.url() <> "/mcp"
    ~s(claude mcp add --transport http helmsman #{url} --header "Authorization: Bearer #{token}")
  end

  ## Rendering helpers

  defp scope_options do
    [
      {"mcp", dgettext("ui", "外接 Agent 通过 MCP 读写任务")},
      {"api:read", dgettext("ui", "通过 REST API 读取数据")},
      {"api:write", dgettext("ui", "通过 REST API 写入数据")}
    ]
  end

  defp expiry_options do
    [
      {dgettext("ui", "不过期"), "never"},
      {dgettext("ui", "30 天"), "30"},
      {dgettext("ui", "90 天"), "90"},
      {dgettext("ui", "1 年"), "365"}
    ]
  end

  defp expired?(%ApiToken{expires_at: at}),
    do: DateTime.compare(at, DateTime.utc_now()) != :gt

  defp revocable?(scope, token) do
    action = if token.user_id == scope.user.id, do: :revoke_own_token, else: :revoke_any_token
    token.revoked_at == nil and Policy.authorize(scope, action, token) == :ok
  end

  @impl true
  def render(assigns) do
    assigns =
      assign(assigns,
        new_path: Url.put_params(assigns.uri || "", %{panel: "new-token"}),
        close_path: Url.drop_params(assigns.uri || "", ["panel"])
      )

    ~H"""
    <.settings_page tab={:tokens} flash={@flash} current_scope={@current_scope} shell={@shell}>
      <:actions>
        <.button
          id="new-token-button"
          variant="primary"
          size="sm"
          icon="lucide-plus"
          patch={@new_path}
          disabled_reason={if(!@can_create?, do: dgettext("ui", "只读成员不能创建 Token"))}
        >
          {dgettext("ui", "新建 Token")}
        </.button>
      </:actions>

      <.settings_section id="own-tokens-section" title={dgettext("ui", "我的 Token")}>
        <.token_table
          id="own-tokens"
          rows={@streams.own}
          scope={@current_scope}
          appearance={@appearance}
        />
        <.empty_state
          :if={@own_empty?}
          icon="lucide-key-round"
          title={dgettext("ui", "还没有 Token")}
          description={dgettext("ui", "Token 让外接 Agent、脚本和 CI 以你的身份访问本工作区")}
        />
      </.settings_section>

      <.settings_section
        :if={@can_list_all?}
        id="all-tokens-section"
        title={dgettext("ui", "工作区全部 Token")}
      >
        <.token_table
          id="all-tokens"
          rows={@streams.all}
          scope={@current_scope}
          appearance={@appearance}
          user_column
        />
      </.settings_section>

      <.side_panel
        :if={@can_create?}
        id="new-token-panel"
        show={@form != nil}
        title={dgettext("ui", "新建 Token")}
        dirty={@form != nil and @token_result == nil and @form.params["name"] != ""}
        patch_on_close={@close_path}
      >
        <div :if={@token_result} id="token-result" class="flex flex-col gap-4">
          <.secret_once id="token-secret" value={@token_result.token} />
          <div :if={@token_result.mcp?} id="token-mcp-command" class="flex flex-col gap-2">
            <p class="text-label font-medium text-fg">
              {dgettext("ui", "在 Claude Code 中添加 Helmsman：")}
            </p>
            <div class="flex items-start gap-2 rounded-field border border-border bg-surface px-2 py-1">
              <code
                id="token-mcp-command-value"
                class="min-w-0 flex-1 break-all font-mono text-label text-fg"
              >
                {mcp_command(@token_result.token)}
              </code>
              <.copy_button
                id="token-mcp-command-copy"
                text={mcp_command(@token_result.token)}
                target="#token-mcp-command-value"
              />
            </div>
          </div>
        </div>
        <.form
          :if={@form && !@token_result}
          for={%{}}
          as={:token}
          id="new-token-form"
          phx-change="validate"
          phx-submit="create"
          class="flex flex-col gap-4"
        >
          <.input
            id="token-name"
            name="token[name]"
            label={dgettext("ui", "名称")}
            value={@form.params["name"]}
            errors={Map.get(@form.errors, :name, [])}
            help={dgettext("ui", "例如 laptop、ci，用于区分不同的使用场景")}
            autocomplete="off"
          />
          <fieldset
            class="flex flex-col gap-1.5"
            aria-describedby={@form.errors[:scopes] && "token-scopes-error"}
          >
            <legend class="mb-1 text-label font-medium text-fg">{dgettext("ui", "权限范围")}</legend>
            <input type="hidden" name="token[scopes][]" value="" />
            <label
              :for={{scope, description} <- scope_options()}
              class="flex cursor-pointer items-start gap-2 text-body text-fg"
            >
              <input
                type="checkbox"
                id={"token-scope-#{String.replace(scope, ":", "-")}"}
                name="token[scopes][]"
                value={scope}
                checked={scope in @form.params["scopes"]}
                class="mt-0.5 size-4 accent-brand"
              />
              <span class="flex flex-col">
                <span class="font-mono">{scope}</span>
                <span class="text-caption text-fg-muted">{description}</span>
              </span>
            </label>
            <p
              :for={msg <- Map.get(@form.errors, :scopes, [])}
              id="token-scopes-error"
              class="flex items-center gap-1 text-caption text-danger-fg"
            >
              <.icon name="lucide-circle-alert" class="size-3.5" />{msg}
            </p>
          </fieldset>
          <.input
            id="token-expires"
            name="token[expires_in]"
            type="select"
            label={dgettext("ui", "有效期")}
            value={@form.params["expires_in"]}
            options={expiry_options()}
          />
          <.input
            :if={@agents != []}
            id="token-default-agent"
            name="token[default_agent_id]"
            type="select"
            label={dgettext("ui", "缺省 Agent")}
            value={@form.params["default_agent_id"]}
            options={[{dgettext("ui", "无"), ""} | Enum.map(@agents, &{&1.name, &1.id})]}
            errors={Map.get(@form.errors, :default_agent_id, [])}
          />
          <div :if={@agents == []} id="token-no-agents" class="flex flex-col gap-1">
            <span class="text-label font-medium text-fg">{dgettext("ui", "缺省 Agent")}</span>
            <p class="text-caption text-fg-muted">
              {dgettext("ui", "外接 Agent 第一次连接时会自动创建身份")}
            </p>
          </div>
        </.form>
        <:footer :let={cancel}>
          <span />
          <div :if={!@token_result} class="flex items-center gap-2">
            <.button phx-click={cancel}>{dgettext("ui", "取消")}</.button>
            <.button
              id="token-submit"
              type="submit"
              form="new-token-form"
              variant="primary"
              phx-disable-with={dgettext("ui", "正在创建…")}
            >
              {dgettext("ui", "创建 Token")}
            </.button>
          </div>
          <.button :if={@token_result} id="token-done" variant="primary" phx-click={cancel}>
            {dgettext("ui", "完成")}
          </.button>
        </:footer>
      </.side_panel>

      <.confirm_dialog
        id="revoke-token-dialog"
        show={@confirm != nil}
        title={@confirm && dgettext("ui", "吊销 %{name}？", name: @confirm.name)}
        danger
        confirm_label={dgettext("ui", "吊销")}
        on_confirm="revoke"
        confirm_value={(@confirm && %{id: @confirm.id}) || %{}}
        on_cancel={JS.push("dismiss")}
      >
        {dgettext("ui", "使用它的 Agent 和脚本将立即无法访问。")}
      </.confirm_dialog>
    </.settings_page>
    """
  end

  attr :id, :string, required: true
  attr :rows, :any, required: true
  attr :scope, :map, required: true
  attr :user_column, :boolean, default: false
  attr :appearance, :map, default: %{}

  defp token_table(assigns) do
    ~H"""
    <.data_table id={@id} rows={@rows} label={dgettext("ui", "Token")}>
      <:col :let={t} :if={@user_column} label={dgettext("ui", "用户")}>
        <span class="truncate text-fg" data-user>{t.user && t.user.display_name}</span>
      </:col>
      <:col :let={t} label={dgettext("ui", "名称")}>
        <span
          class={["truncate", if(t.revoked_at, do: "text-fg-subtle line-through", else: "text-fg")]}
          data-name
        >
          {t.name}
        </span>
      </:col>
      <:col :let={t} label={dgettext("ui", "前缀")}>
        <code class="font-mono text-label text-fg-muted" data-prefix>hm_{t.prefix}…</code>
      </:col>
      <:col :let={t} label={dgettext("ui", "权限范围")} secondary>
        <span class="flex flex-wrap gap-1" data-scopes>
          <.badge :for={s <- t.scopes}>{s}</.badge>
        </span>
      </:col>
      <:col :let={t} label={dgettext("ui", "缺省 Agent")} secondary>
        <span class="flex min-w-0" data-agent>
          <.actor_chip
            :if={t.default_agent}
            actor={Appearance.decorate(%{name: t.default_agent.name, kind: :agent}, @appearance)}
          />
          <span :if={!t.default_agent} class="text-fg-muted">—</span>
        </span>
      </:col>
      <:col :let={t} label={dgettext("ui", "最近使用")} secondary>
        <.relative_time
          :if={t.last_used_at}
          id={"#{@id}-#{t.id}-used"}
          at={t.last_used_at}
          class="text-fg-muted"
        />
        <span :if={!t.last_used_at} class="text-fg-muted" data-never-used>{dgettext("ui", "从未使用")}</span>
      </:col>
      <:col :let={t} label={dgettext("ui", "过期")} secondary>
        <span :if={!t.expires_at} class="text-fg-muted" data-expires>{dgettext("ui", "不过期")}</span>
        <span :if={t.expires_at} class="inline-flex items-center gap-1 text-fg-muted" data-expires>
          {Calendar.strftime(t.expires_at, "%Y-%m-%d")}
          <.badge :if={expired?(t)} tone={:warning} data-expired>{dgettext("ui", "已过期")}</.badge>
        </span>
      </:col>
      <:col :let={t} label="" class="w-24 text-right">
        <.badge :if={t.revoked_at} data-revoked>{dgettext("ui", "已吊销")}</.badge>
        <.button
          :if={revocable?(@scope, t)}
          id={"#{@id}-#{t.id}-revoke"}
          size="xs"
          variant="ghost"
          phx-click="ask_revoke"
          phx-value-id={t.id}
        >
          {dgettext("ui", "吊销")}
        </.button>
      </:col>
    </.data_table>
    """
  end
end
