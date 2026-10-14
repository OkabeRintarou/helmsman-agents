defmodule HelmsmanWeb.UserLive.ProviderAccounts do
  @moduledoc """
  `/users/settings/provider-accounts` (spec web-provider-accounts; add-provider-accounts-ui
  D1, D4–D7): the current user's provider accounts, the new / edit panel driven by
  `?panel=new` and `?panel=edit&id=<id>` (`HelmsmanWeb.ProviderAccountForm`), deletion
  with confirmation, and live refresh.

  Subscribes to the user's account topic before reading; `{:provider_accounts_changed}`
  (accounts created, changed or deleted, and agents bound or unbound) reloads the whole
  list through `HelmsmanWeb.Throttle` and refreshes an open edit panel.
  """
  use HelmsmanWeb, :live_view

  import HelmsmanWeb.AgentComponents, only: [provider_label: 1]

  import HelmsmanWeb.ProviderAccountComponents,
    only: [
      accounts_path: 0,
      account_icon: 1,
      account_icon_mark: 1,
      edit_path: 1,
      mapping_lines: 1,
      split_url: 1
    ]

  alias Helmsman.{Events, ProviderAccounts}
  alias HelmsmanWeb.{AvatarData, ProviderAccountForm, Throttle, Url}

  @shown_agents 2

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope

    if connected?(socket), do: Events.subscribe(ProviderAccounts.topic(scope.user.id))

    {:ok,
     socket
     |> assign(
       page_title: dgettext("ui", "供应商账号"),
       max: ProviderAccounts.max_accounts(),
       accounts: [],
       account_form: nil,
       form_gen: 0,
       confirm: nil,
       in_use: nil,
       avatar: AvatarData.user_avatar(scope.user)
     )
     |> stream_configure(:accounts, dom_id: &"provider-account-#{&1.id}")
     |> stream(:accounts, [])
     |> load()}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    case params["panel"] do
      "new" -> {:noreply, open_new(socket)}
      "edit" -> {:noreply, open_edit(socket, params["id"])}
      _ -> {:noreply, assign(socket, :account_form, nil)}
    end
  end

  defp open_new(%{assigns: %{account_form: %{mode: :new}}} = socket), do: socket

  defp open_new(socket) do
    if full?(socket.assigns) do
      socket
      |> assign(:account_form, nil)
      |> put_flash(:error, limit_text(socket.assigns.max))
      |> drop_panel_param()
    else
      gen = socket.assigns.form_gen + 1
      assign(socket, form_gen: gen, account_form: ProviderAccountForm.new(gen))
    end
  end

  defp open_edit(%{assigns: %{account_form: %{mode: :edit, id: id}}} = socket, raw_id)
       when is_binary(raw_id) do
    if to_string(id) == raw_id,
      do: socket,
      else: open_edit(%{socket | assigns: drop_form(socket)}, raw_id)
  end

  defp open_edit(socket, raw_id) do
    case ProviderAccounts.get(socket.assigns.current_scope, raw_id || "") do
      {:ok, view} ->
        gen = socket.assigns.form_gen + 1
        assign(socket, form_gen: gen, account_form: ProviderAccountForm.edit(gen, view))

      {:error, _} ->
        socket
        |> assign(:account_form, nil)
        |> put_flash(:error, dgettext("ui", "供应商账号不存在"))
        |> drop_panel_param()
    end
  end

  # The dead render only shows the flash; the connected one also drops the parameters.
  defp drop_panel_param(socket) do
    if connected?(socket),
      do: push_patch(socket, to: accounts_path(), replace: true),
      else: socket
  end

  defp drop_form(socket), do: Map.put(socket.assigns, :account_form, nil)

  defp full?(%{accounts: accounts, max: max}), do: length(accounts) >= max

  defp limit_text(max), do: dgettext("ui", "最多 %{n} 个供应商账号", n: max)

  defp load(socket) do
    accounts =
      case ProviderAccounts.list(socket.assigns.current_scope) do
        {:ok, views} -> Enum.sort_by(views, &{String.downcase(&1.name), &1.id})
        {:error, _} -> []
      end

    socket
    |> assign(:accounts, accounts)
    |> stream(:accounts, accounts, reset: true)
  end

  ## Events

  @impl true
  def handle_event("account_form_" <> _ = event, params, socket) do
    case ProviderAccountForm.handle_event(event, params, socket) do
      {:saved, view, socket} ->
        message =
          if socket.assigns.account_form.mode == :new,
            do: dgettext("ui", "已创建 %{name}", name: view.name),
            else: dgettext("ui", "已保存")

        {:noreply,
         socket
         |> assign(:account_form, nil)
         |> load()
         |> put_flash(:info, message)
         |> push_patch(to: accounts_path())}

      result ->
        result
    end
  end

  def handle_event("ask_delete", %{"id" => id}, socket) do
    case find(socket, id) do
      %{agents: [], id: id, name: name} ->
        {:noreply, assign(socket, :confirm, %{id: id, name: name})}

      _ ->
        {:noreply, socket}
    end
  end

  # The dialog runs its `on_cancel` ("dismiss") before pushing "delete": the account
  # comes with the event.
  def handle_event("delete", %{"id" => id, "name" => name}, socket) do
    socket = assign(socket, :confirm, nil)

    case ProviderAccounts.delete(socket.assigns.current_scope, id) do
      :ok ->
        {:noreply,
         socket |> load() |> put_flash(:info, dgettext("ui", "已删除 %{name}", name: name))}

      {:error, {:in_use, agents}} ->
        {:noreply, socket |> assign(:in_use, %{name: name, agents: agents}) |> load()}

      {:error, :not_found} ->
        {:noreply, socket |> load() |> put_flash(:error, dgettext("ui", "供应商账号已被删除"))}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, ProviderAccountForm.error_text(:forbidden))}
    end
  end

  def handle_event("delete", _params, socket), do: {:noreply, socket}
  def handle_event("dismiss", _params, socket), do: {:noreply, assign(socket, :confirm, nil)}

  def handle_event("dismiss_in_use", _params, socket),
    do: {:noreply, assign(socket, :in_use, nil)}

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  defp find(socket, id) do
    id = to_string(id)
    Enum.find(socket.assigns.accounts, &(to_string(&1.id) == id))
  end

  @impl true
  def handle_info({:provider_accounts_changed}, socket),
    do: {:noreply, Throttle.schedule(socket)}

  def handle_info(:reload, socket) do
    socket = socket |> Throttle.done() |> load()

    case socket.assigns.account_form do
      nil ->
        {:noreply, socket}

      form ->
        {:noreply,
         assign(
           socket,
           :account_form,
           ProviderAccountForm.refreshed(form, socket.assigns.accounts)
         )}
    end
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  ## Rendering

  defp default_model(models) do
    case models["default"] do
      nil -> "—"
      model -> model
    end
  end

  defp extra_count(models), do: models |> Map.delete("default") |> map_size()

  defp row_menu(account) do
    n = length(account.agents)

    delete =
      %{
        id: "provider-account-#{account.id}-delete",
        label: dgettext("ui", "删除"),
        icon: "lucide-trash",
        danger: true,
        on_select: "ask_delete",
        value: %{id: account.id}
      }

    delete =
      if n > 0,
        do:
          Map.put(
            delete,
            :disabled_reason,
            dngettext("ui", "被 %{count} 个 Agent 使用，不能删除", "被 %{count} 个 Agent 使用，不能删除", n)
          ),
        else: delete

    [
      %{
        id: "provider-account-#{account.id}-edit",
        label: dgettext("ui", "编辑"),
        icon: "lucide-pencil",
        patch: edit_path(account.id)
      },
      delete
    ]
  end

  @impl true
  def render(assigns) do
    assigns =
      assign(assigns,
        count: length(assigns.accounts),
        shown_agents: @shown_agents
      )

    ~H"""
    <Layouts.personal
      flash={@flash}
      current_scope={@current_scope}
      active={:provider_accounts}
      avatar={@avatar}
    >
      <div class="flex flex-wrap items-start justify-between gap-3">
        <div class="min-w-0">
          <h2 class="text-title font-semibold text-fg">{dgettext("ui", "供应商账号")}</h2>
          <p class="mt-1 text-body text-fg-muted">
            {dgettext("ui", "密钥加密保存，保存后不能查看；Agent 在 Agent 设置里选择账号。")}
          </p>
        </div>
        <div class="flex items-center gap-3">
          <span id="provider-accounts-count" class="text-body text-fg-muted">
            {@count} / {@max}
          </span>
          <.button
            id="provider-accounts-new"
            variant="primary"
            size="sm"
            icon="lucide-plus"
            patch={"#{accounts_path()}?panel=new"}
            disabled_reason={if(@count >= @max, do: limit_text(@max))}
          >
            {dgettext("ui", "新建账号")}
          </.button>
        </div>
      </div>

      <div :if={@accounts == []} id="provider-accounts-empty" class="mt-6">
        <.empty_state
          icon="lucide-key-round"
          title={dgettext("ui", "还没有供应商账号")}
          description={
            dgettext(
              "ui",
              "为托管 Agent 指定模型供应商的地址、密钥与模型；同一个 CLI 可以有多个账号，Agent 各选其一"
            )
          }
        >
          <:action>
            <.button
              id="provider-accounts-empty-new"
              variant="primary"
              size="sm"
              icon="lucide-plus"
              patch={"#{accounts_path()}?panel=new"}
            >
              {dgettext("ui", "新建账号")}
            </.button>
          </:action>
        </.empty_state>
      </div>

      <div :if={@accounts != []} class="mt-4 overflow-x-auto">
        <.data_table
          id="provider-accounts"
          rows={@streams.accounts}
          label={dgettext("ui", "供应商账号")}
          rich
          class="min-w-[560px]"
          row_version={& &1.updated_at}
          row_click={&JS.patch(edit_path(&1.id))}
        >
          <:col :let={a} label={dgettext("ui", "名称")} class="w-[13%]">
            <span class="flex min-w-0 items-center gap-2">
              <.account_icon_mark account={a} />
              <span class="truncate font-semibold text-fg" data-name>{a.name}</span>
            </span>
          </:col>
          <:col :let={a} label="CLI" class="w-[13%]">
            <span class="text-fg-muted" data-cli>{provider_label(a.cli)}</span>
          </:col>
          <:col :let={a} label={dgettext("ui", "地址")} class="w-[20%]">
            <.address url={a.base_url} />
            <span
              :if={a.headers != []}
              class="block truncate font-mono text-caption text-fg-muted"
              title={Enum.join(a.headers, "\n")}
              data-headers
            >
              <span class="font-sans">{dgettext("ui", "请求头")}</span>
              <span :for={h <- a.headers} class="ml-1" data-header>{h}</span>
            </span>
          </:col>
          <:col :let={a} label={dgettext("ui", "缺省模型")} class="w-[13%]" secondary>
            <span
              class="font-mono text-label text-fg"
              title={Enum.join(mapping_lines(a.models), "\n")}
              data-default-model
            >
              <.model_label
                :if={a.models["default"]}
                model={a.models["default"]}
                account_icon={account_icon(a)}
              />
              <span :if={!a.models["default"]}>{default_model(a.models)}</span><span
                :if={extra_count(a.models) > 0}
                class="ml-1 text-fg-muted"
              >+{extra_count(a.models)}</span>
            </span>
          </:col>
          <:col :let={a} label={dgettext("ui", "密钥")} class="w-[9%]" secondary>
            <.badge :if={a.api_key_set} tone={:success} data-api-key>{dgettext("ui", "已设置")}</.badge>
            <.badge :if={!a.api_key_set} tone={:warning} data-api-key>
              {dgettext("ui", "未设置")}
            </.badge>
          </:col>
          <:col :let={a} label={dgettext("ui", "使用中")} class="w-[15%]">
            <span class="flex min-w-0 items-center gap-1" data-agents>
              <span :if={a.agents == []} class="text-fg-subtle">{dgettext("ui", "未使用")}</span>
              <span
                :for={ag <- Enum.take(a.agents, @shown_agents)}
                class="truncate rounded-badge bg-hover px-1.5 font-mono text-caption text-fg"
                data-agent
              >
                {ag.workspace_slug}/{ag.name}
              </span>
              <span
                :if={length(a.agents) > @shown_agents}
                class="text-caption text-fg-muted"
                title={Enum.map_join(a.agents, "\n", &"#{&1.workspace_slug}/#{&1.name}")}
              >
                +{length(a.agents) - @shown_agents}
              </span>
            </span>
          </:col>
          <:col :let={a} label={dgettext("ui", "更新时间")} class="w-[10%]" secondary>
            <.relative_time
              id={"provider-account-#{a.id}-updated"}
              at={a.updated_at}
              class="text-fg-muted"
            />
          </:col>
          <:col :let={a} class="w-12 text-right">
            <.dropdown
              id={"provider-account-#{a.id}-actions"}
              label={dgettext("ui", "更多操作")}
              align={:end}
              items={row_menu(a)}
            >
              <:trigger><.icon name="lucide-ellipsis" class="size-4" /></:trigger>
            </.dropdown>
          </:col>
        </.data_table>
      </div>

      <ProviderAccountForm.panel form={@account_form} close_path={accounts_path()} />

      <.confirm_dialog
        id="provider-account-confirm"
        show={@confirm != nil}
        title={@confirm && dgettext("ui", "删除 %{name}？", name: @confirm.name)}
        danger
        confirm_label={dgettext("ui", "删除")}
        on_confirm="delete"
        confirm_value={if(@confirm, do: %{id: @confirm.id, name: @confirm.name}, else: %{})}
        on_cancel={JS.push("dismiss")}
      >
        {dgettext("ui", "删除后不能恢复；已结束的运行不再显示所用账号。")}
      </.confirm_dialog>

      <.in_use_dialog in_use={@in_use} />
    </Layouts.personal>
    """
  end

  attr :url, :string, required: true

  defp address(assigns) do
    {scheme, host, rest} = split_url(assigns.url)
    assigns = assign(assigns, scheme: scheme, host: host, rest: rest)

    ~H"""
    <span class="block truncate font-mono text-label" title={@url} data-address>
      <span class="text-fg-subtle">{@scheme}</span><span class="text-fg" data-host>{@host}</span><span class="text-fg-muted">{@rest}</span>
    </span>
    """
  end

  attr :in_use, :map, default: nil

  # The deletion was refused because agents were bound meanwhile: a small modal listing
  # them (the confirm dialog only holds one sentence).
  defp in_use_dialog(assigns) do
    ~H"""
    <.modal
      id="provider-account-in-use"
      show={@in_use != nil}
      size={:sm}
      title={(@in_use && dgettext("ui", "不能删除 %{name}", name: @in_use.name)) || ""}
      on_cancel={JS.push("dismiss_in_use")}
    >
      <div :if={@in_use} class="flex flex-col gap-2">
        <p class="text-body text-fg">
          {dgettext("ui", "仍被以下 Agent 使用，先在这些 Agent 的设置里改用其他账号：")}
        </p>
        <ul class="flex flex-col gap-1">
          <li :for={a <- @in_use.agents}>
            <.link
              navigate={Url.agent_path(a.workspace_slug, a.name)}
              class="font-mono text-label text-fg hover:underline"
              data-in-use-agent
            >
              {a.workspace_slug}/{a.name}
            </.link>
          </li>
        </ul>
      </div>
      <:footer :let={cancel}>
        <.button id="provider-account-in-use-ok" variant="primary" phx-click={cancel}>
          {dgettext("ui", "知道了")}
        </.button>
      </:footer>
    </.modal>
    """
  end
end
