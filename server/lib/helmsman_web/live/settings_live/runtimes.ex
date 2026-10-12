defmodule HelmsmanWeb.SettingsLive.Runtimes do
  @moduledoc """
  `/w/:slug/settings/runtimes` (spec web-runtimes 运行时页, design D7): the user's
  machines (daemons, every workspace) and the workspace's runtimes (mine, or all with
  `?all=1` for admins). Panels `?panel=rename:<id>` and `?panel=workspaces:<id>`.

  `{:runtimes_changed}` / `{:daemons_changed}` (forwarded by the shell) reload the lists
  through `HelmsmanWeb.Throttle`; `:tick` every 30 seconds re-reads the machines so the
  online dots follow `last_seen_at`. Open panels keep their input across reloads.
  """
  use HelmsmanWeb, :live_view

  import HelmsmanWeb.AgentComponents

  alias Helmsman.{Daemons, Policy, Runtimes, Workspaces}
  alias HelmsmanWeb.{FormErrors, RunData, Throttle, Url}

  @tick_ms 30_000
  @member_roles [:owner, :admin, :member]

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope

    if Policy.authorize(scope, :manage_runtimes) == :ok do
      if connected?(socket), do: :timer.send_interval(@tick_ms, self(), :tick)

      {:ok,
       assign(socket,
         page_title: dgettext("ui", "运行时"),
         admin?: Policy.authorize(scope, :list_all_runtimes) == :ok,
         all?: false,
         uri: nil,
         panel: nil,
         confirm: nil,
         daemons: [],
         runtimes: []
       )}
    else
      {:ok,
       socket
       |> put_flash(:error, dgettext("ui", "没有权限访问运行时"))
       |> push_navigate(to: "/w/#{scope.workspace.slug}/settings")}
    end
  end

  @impl true
  def handle_params(params, uri, socket) do
    %URI{path: path, query: query} = URI.parse(uri)
    all? = socket.assigns.admin? and params["all"] == "1"
    socket = assign(socket, uri: if(query, do: "#{path}?#{query}", else: path))

    socket =
      if all? != socket.assigns.all? or socket.assigns.runtimes == [],
        do: socket |> assign(:all?, all?) |> load(),
        else: socket

    {:noreply, open_panel(socket, params["panel"])}
  end

  defp load(socket) do
    scope = socket.assigns.current_scope

    runtimes =
      case Runtimes.list(scope, all: socket.assigns.all?) do
        {:ok, runtimes} -> runtimes
        {:error, _} -> []
      end

    assign(socket, daemons: RunData.daemons(scope), runtimes: runtimes)
  end

  defp open_panel(socket, panel) do
    case parse_panel(panel, socket.assigns.daemons) do
      nil ->
        assign(socket, :panel, nil)

      {kind, daemon} ->
        case socket.assigns.panel do
          %{kind: ^kind, id: id} = open when id == daemon.id -> assign(socket, :panel, open)
          _ -> assign(socket, :panel, new_panel(socket, kind, daemon))
        end
    end
  end

  defp parse_panel(panel, daemons) when is_binary(panel) do
    with [kind, id] when kind in ["rename", "workspaces"] <- String.split(panel, ":", parts: 2),
         {id, ""} <- Integer.parse(id),
         %{revoked: false} = daemon <- Enum.find(daemons, &(&1.id == id)) do
      {String.to_existing_atom(kind), daemon}
    else
      _ -> nil
    end
  end

  defp parse_panel(_panel, _daemons), do: nil

  defp new_panel(_socket, :rename, daemon),
    do: %{kind: :rename, id: daemon.id, name: daemon.name, errors: %{}, error: nil}

  defp new_panel(socket, :workspaces, daemon) do
    candidates =
      for %{workspace: w, role: role} <-
            Workspaces.list_for_user(socket.assigns.current_scope.user),
          role in @member_roles,
          do: w

    %{
      kind: :workspaces,
      id: daemon.id,
      candidates: candidates,
      selected: MapSet.new(daemon.workspaces, & &1.id),
      invalid: MapSet.new(),
      error: nil
    }
  end

  ## Events

  @impl true
  def handle_event("validate_rename", %{"rename" => %{"name" => name}}, socket),
    do: {:noreply, update_panel(socket, :rename, &%{&1 | name: name})}

  def handle_event("rename", %{"rename" => %{"name" => name}}, socket) do
    with %{kind: :rename, id: id} <- socket.assigns.panel,
         {:ok, name} <- present(name, socket) do
      case Daemons.rename(socket.assigns.current_scope, id, name) do
        {:ok, _} ->
          {:noreply, socket |> put_flash(:info, dgettext("ui", "已改名")) |> load() |> close_panel()}

        {:error, %Ecto.Changeset{} = changeset} ->
          errors = FormErrors.messages(changeset)
          {:noreply, update_panel(socket, :rename, &%{&1 | name: name, errors: errors})}

        {:error, reason} ->
          {:noreply, panel_error(socket, reason)}
      end
    else
      {:blank, socket} -> {:noreply, socket}
      _ -> {:noreply, socket}
    end
  end

  def handle_event("select_workspaces", params, socket) do
    ids = selected_ids(params)
    {:noreply, update_panel(socket, :workspaces, &%{&1 | selected: MapSet.new(ids)})}
  end

  def handle_event("save_workspaces", params, socket) do
    case socket.assigns.panel do
      %{kind: :workspaces, id: id} -> save_workspaces(socket, id, selected_ids(params))
      _ -> {:noreply, socket}
    end
  end

  def handle_event("ask_revoke", %{"id" => id}, socket) do
    case find(socket.assigns.daemons, id) do
      %{revoked: false} = daemon ->
        {:noreply, assign(socket, :confirm, %{kind: :revoke, id: daemon.id, name: daemon.name})}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("revoke", %{"id" => id}, socket) do
    with %{} = daemon <- find(socket.assigns.daemons, id),
         {:ok, _} <- Daemons.revoke(socket.assigns.current_scope, daemon.id) do
      {:noreply,
       socket
       |> assign(:confirm, nil)
       |> put_flash(:info, dgettext("ui", "已吊销 %{name}", name: daemon.name))
       |> load()}
    else
      nil -> {:noreply, assign(socket, :confirm, nil)}
      {:error, reason} -> {:noreply, failed(socket, reason)}
    end
  end

  def handle_event("ask_disable", %{"id" => id}, socket) do
    case find(socket.assigns.runtimes, id) do
      %{} = runtime -> {:noreply, assign(socket, :confirm, %{kind: :disable, id: runtime.id})}
      nil -> {:noreply, socket}
    end
  end

  def handle_event("disable", %{"id" => id}, socket), do: set_disabled(socket, id, true)
  def handle_event("enable", %{"id" => id}, socket), do: set_disabled(socket, id, false)

  def handle_event("dismiss", _params, socket), do: {:noreply, assign(socket, :confirm, nil)}

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  defp save_workspaces(socket, id, ids) do
    case Daemons.set_workspaces(socket.assigns.current_scope, id, ids) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, dgettext("ui", "已更新服务的工作区"))
         |> load()
         |> close_panel()}

      {:error, {:invalid_workspaces, invalid}} ->
        {:noreply,
         update_panel(socket, :workspaces, fn panel ->
           %{
             panel
             | selected: MapSet.new(ids),
               invalid: MapSet.new(invalid),
               error: dgettext("ui", "你在标出的工作区里不能运行 Agent")
           }
         end)}

      {:error, reason} ->
        {:noreply, panel_error(socket, reason)}
    end
  end

  defp set_disabled(socket, id, disabled) do
    scope = socket.assigns.current_scope

    with %{} = runtime <- find(socket.assigns.runtimes, id),
         {:ok, _} <-
           if(disabled,
             do: Runtimes.disable(scope, runtime.id),
             else: Runtimes.enable(scope, runtime.id)
           ) do
      message = if disabled, do: dgettext("ui", "运行时已禁用"), else: dgettext("ui", "运行时已启用")
      {:noreply, socket |> assign(:confirm, nil) |> put_flash(:info, message) |> load()}
    else
      nil -> {:noreply, assign(socket, :confirm, nil)}
      {:error, reason} -> {:noreply, failed(socket, reason)}
    end
  end

  @impl true
  def handle_info(message, socket) when message in [{:runtimes_changed}, {:daemons_changed}],
    do: {:noreply, Throttle.schedule(socket)}

  def handle_info(:reload, socket), do: {:noreply, socket |> Throttle.done() |> load()}

  def handle_info(:tick, socket),
    do: {:noreply, assign(socket, :daemons, RunData.daemons(socket.assigns.current_scope))}

  def handle_info(_message, socket), do: {:noreply, socket}

  defp failed(socket, reason) do
    socket |> assign(:confirm, nil) |> put_flash(:error, error_message(reason)) |> load()
  end

  defp panel_error(socket, reason) do
    case socket.assigns.panel do
      nil -> failed(socket, reason)
      panel -> assign(socket, :panel, %{panel | error: error_message(reason)})
    end
  end

  defp error_message(:forbidden), do: dgettext("ui", "没有权限执行此操作")
  defp error_message(:not_found), do: dgettext("ui", "运行时不存在")
  defp error_message(_reason), do: dgettext("ui", "操作失败，请重试")

  defp present(name, socket) do
    if String.trim(name) == "" do
      errors = %{name: [dgettext("ui", "请填写名字")]}
      {:blank, update_panel(socket, :rename, &%{&1 | name: name, errors: errors})}
    else
      {:ok, name}
    end
  end

  defp update_panel(socket, kind, fun) do
    case socket.assigns.panel do
      %{kind: ^kind} = panel -> assign(socket, :panel, fun.(panel))
      _ -> socket
    end
  end

  defp close_panel(socket) do
    socket
    |> assign(:panel, nil)
    |> push_patch(to: Url.drop_params(socket.assigns.uri, ["panel"]))
  end

  defp selected_ids(params) do
    params
    |> Map.get("workspace_ids", [])
    |> List.wrap()
    |> Enum.flat_map(fn id ->
      case Integer.parse(to_string(id)) do
        {id, ""} -> [id]
        _ -> []
      end
    end)
  end

  defp find(list, id) do
    case Integer.parse(to_string(id)) do
      {id, ""} -> Enum.find(list, &(&1.id == id))
      _ -> nil
    end
  end

  ## Rendering

  defp can_toggle?(scope, runtime),
    do: Policy.authorize(scope, :disable_runtime, %{user_id: runtime.daemon.user.id}) == :ok

  defp panel_path(uri, kind, id), do: Url.put_params(uri, %{panel: "#{kind}:#{id}"})

  defp login_command, do: "helmsman login --server #{HelmsmanWeb.Endpoint.url()}"

  defp panel_title(%{kind: :rename}), do: dgettext("ui", "改名")
  defp panel_title(%{kind: :workspaces}), do: dgettext("ui", "服务的工作区")
  defp panel_title(_), do: ""

  defp confirm_title(%{kind: :revoke, name: name}), do: dgettext("ui", "吊销 %{name}？", name: name)
  defp confirm_title(%{kind: :disable}), do: dgettext("ui", "禁用运行时？")
  defp confirm_title(_), do: ""

  defp confirm_text(%{kind: :revoke}),
    do: dgettext("ui", "吊销后这台机器立即断开，它的运行时全部离线，需要重新 helmsman login")

  defp confirm_text(%{kind: :disable}),
    do: dgettext("ui", "已绑定的 Agent 不会再被派发运行，排队中的运行会被取消")

  defp confirm_text(_), do: ""

  @impl true
  def render(assigns) do
    assigns =
      assign(assigns,
        empty?: assigns.daemons == [] and assigns.runtimes == [],
        close_path: Url.drop_params(assigns.uri || "", ["panel"])
      )

    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} shell={@shell}>
      <:header>
        <.page_header title={dgettext("ui", "运行时")} />
      </:header>
      <div class="mx-auto w-full max-w-5xl px-4 pt-6 pb-10 sm:px-6">
        <div
          :if={@empty?}
          id="runtimes-empty"
          class="flex flex-col items-center gap-4 rounded-box border border-border bg-surface px-6 py-10 text-center"
        >
          <.icon name="lucide-server" class="size-8 text-fg-subtle" />
          <p class="max-w-md text-body text-fg-muted">
            {dgettext("ui", "在你的电脑上安装 Helmsman 守护进程并登录，它会把检测到的 Agent CLI 登记为运行时")}
          </p>
          <div class="flex w-full max-w-lg flex-col gap-2 text-left">
            <.command id="login-command" text={login_command()} />
            <.command id="start-command" text="helmsman daemon start" />
          </div>
        </div>

        <section :if={!@empty?} id="daemons-section" class="mb-8">
          <h2 class="mb-2 text-title font-semibold text-fg">{dgettext("ui", "我的机器")}</h2>
          <p :if={@daemons == []} class="text-body text-fg-muted">{dgettext("ui", "还没有登录过的机器")}</p>
          <ul class="flex flex-col divide-y divide-border rounded-box border border-border bg-surface">
            <li
              :for={d <- @daemons}
              id={"daemon-#{d.id}"}
              class="flex items-center gap-3 px-4 py-3"
              data-revoked={d.revoked}
            >
              <.presence_dot status={if(d.online, do: :online, else: :offline)} />
              <div class="flex min-w-0 flex-1 flex-col">
                <span class="flex items-center gap-2 text-body text-fg">
                  <span class="truncate font-medium" data-daemon-name>{d.name}</span>
                  <.badge :if={d.revoked} tone={:danger} data-revoked-badge>
                    {dgettext("ui", "已吊销")}
                  </.badge>
                </span>
                <span class="flex flex-wrap items-center gap-x-2 text-caption text-fg-muted">
                  <span>{d.os} / {d.arch}</span>
                  <span>v{d.version}</span>
                  <span :if={d.last_seen_at}>
                    {dgettext("ui", "最近上报")}
                    <.relative_time id={"daemon-#{d.id}-seen"} at={d.last_seen_at} />
                  </span>
                  <span data-daemon-workspaces>
                    {Enum.map_join(d.workspaces, "、", & &1.name)}
                  </span>
                </span>
              </div>
              <.dropdown
                :if={!d.revoked}
                id={"daemon-#{d.id}-actions"}
                label={dgettext("ui", "更多操作")}
                align={:end}
                items={[
                  %{
                    id: "daemon-#{d.id}-rename",
                    label: dgettext("ui", "改名"),
                    icon: "lucide-pencil",
                    patch: panel_path(@uri, "rename", d.id)
                  },
                  %{
                    id: "daemon-#{d.id}-workspaces",
                    label: dgettext("ui", "服务的工作区"),
                    icon: "lucide-layers",
                    patch: panel_path(@uri, "workspaces", d.id)
                  },
                  %{
                    id: "daemon-#{d.id}-revoke",
                    label: dgettext("ui", "吊销"),
                    icon: "lucide-ban",
                    danger: true,
                    on_select: "ask_revoke",
                    value: %{id: d.id}
                  }
                ]}
              >
                <:trigger><.icon name="lucide-ellipsis" class="size-4" /></:trigger>
              </.dropdown>
            </li>
          </ul>
        </section>

        <section :if={!@empty? or @admin?} id="runtimes-section" class={@empty? && "mt-8"}>
          <div class="mb-2 flex items-center justify-between gap-2">
            <h2 class="text-title font-semibold text-fg">{dgettext("ui", "运行时")}</h2>
            <nav
              :if={@admin?}
              id="runtimes-scope"
              class="flex gap-1"
              aria-label={dgettext("ui", "范围")}
            >
              <.link
                id="runtimes-mine"
                patch={Url.drop_params(@uri || "", ["all"])}
                aria-current={!@all? && "page"}
                class={[
                  "rounded-field px-2 py-1 text-body",
                  !@all? && "bg-selected text-fg",
                  @all? && "text-fg-muted hover:bg-hover"
                ]}
              >
                {dgettext("ui", "我的")}
              </.link>
              <.link
                id="runtimes-all"
                patch={Url.put_params(@uri || "", %{all: "1"})}
                aria-current={@all? && "page"}
                class={[
                  "rounded-field px-2 py-1 text-body",
                  @all? && "bg-selected text-fg",
                  !@all? && "text-fg-muted hover:bg-hover"
                ]}
              >
                {dgettext("ui", "全部")}
              </.link>
            </nav>
          </div>
          <p :if={@runtimes == []} id="runtimes-none" class="text-body text-fg-muted">
            {dgettext("ui", "本工作区还没有运行时")}
          </p>
          <div
            :if={@runtimes != []}
            class="overflow-x-auto rounded-box border border-border bg-surface"
          >
            <table id="runtimes" class="w-full text-body">
              <caption class="sr-only">{dgettext("ui", "运行时")}</caption>
              <thead class="text-left text-caption text-fg-muted">
                <tr class="border-b border-border">
                  <th class="px-3 py-2 font-medium">{dgettext("ui", "机器")}</th>
                  <th :if={@all?} class="px-3 py-2 font-medium">{dgettext("ui", "所属用户")}</th>
                  <th class="px-3 py-2 font-medium">CLI</th>
                  <th class="px-3 py-2 font-medium">{dgettext("ui", "版本")}</th>
                  <th class="px-3 py-2 font-medium">{dgettext("ui", "模型")}</th>
                  <th class="px-3 py-2 font-medium">{dgettext("ui", "状态")}</th>
                  <th class="px-3 py-2 font-medium">{dgettext("ui", "绑定的 Agent")}</th>
                  <th class="px-3 py-2"><span class="sr-only">{dgettext("ui", "操作")}</span></th>
                </tr>
              </thead>
              <tbody class="divide-y divide-border">
                <tr :for={r <- @runtimes} id={"runtime-#{r.id}"}>
                  <td class="px-3 py-2 text-fg" data-machine>{r.daemon.name}</td>
                  <td :if={@all?} class="px-3 py-2 text-fg-muted" data-owner>{r.daemon.user.name}</td>
                  <td class="px-3 py-2"><.provider provider={r.provider} /></td>
                  <td class="px-3 py-2 text-fg-muted">{r.cli_version}</td>
                  <td class="px-3 py-2 text-fg-muted">
                    <span
                      :if={r.models != []}
                      class="hm-tooltip-host relative"
                      tabindex="0"
                      data-models
                    >
                      {length(r.models)}
                      <span role="tooltip" class={tooltip_class(:bottom)}>{Enum.join(r.models, "、")}</span>
                    </span>
                  </td>
                  <td class="px-3 py-2">
                    <.runtime_badge id={"runtime-#{r.id}-status"} runtime={r} />
                  </td>
                  <td class="px-3 py-2">
                    <span class="flex flex-wrap gap-x-2">
                      <.link
                        :for={name <- r.agents}
                        navigate={Url.agent_path(@current_scope.workspace.slug, name)}
                        class="text-brand-fg hover:underline"
                        data-agent={name}
                      >
                        {name}
                      </.link>
                    </span>
                  </td>
                  <td class="px-3 py-2 text-right">
                    <.button
                      :if={can_toggle?(@current_scope, r) and !r.disabled}
                      id={"runtime-#{r.id}-disable"}
                      size="xs"
                      variant="ghost"
                      phx-click="ask_disable"
                      phx-value-id={r.id}
                    >
                      {dgettext("ui", "禁用")}
                    </.button>
                    <.button
                      :if={can_toggle?(@current_scope, r) and r.disabled}
                      id={"runtime-#{r.id}-enable"}
                      size="xs"
                      variant="ghost"
                      phx-click="enable"
                      phx-value-id={r.id}
                    >
                      {dgettext("ui", "启用")}
                    </.button>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </section>
      </div>

      <.side_panel
        id="daemon-panel"
        show={@panel != nil}
        title={panel_title(@panel)}
        patch_on_close={@close_path}
      >
        <:error :if={@panel && @panel.error}>{@panel.error}</:error>
        <.form
          :if={@panel && @panel.kind == :rename}
          for={%{}}
          as={:rename}
          id="rename-form"
          phx-change="validate_rename"
          phx-submit="rename"
        >
          <.input
            id="rename-name"
            name="rename[name]"
            label={dgettext("ui", "名字")}
            value={@panel.name}
            maxlength="64"
            errors={Map.get(@panel.errors, :name, [])}
          />
        </.form>
        <.form
          :if={@panel && @panel.kind == :workspaces}
          for={%{}}
          id="workspaces-form"
          phx-change="select_workspaces"
          phx-submit="save_workspaces"
          class="flex flex-col gap-1"
        >
          <input type="hidden" name="workspace_ids[]" value="" />
          <label
            :for={w <- @panel.candidates}
            id={"daemon-workspace-#{w.id}"}
            data-invalid={MapSet.member?(@panel.invalid, w.id)}
            class={[
              "flex items-center gap-2 rounded-field px-2 py-1.5",
              MapSet.member?(@panel.invalid, w.id) && "border border-danger tint-danger"
            ]}
          >
            <input
              type="checkbox"
              name="workspace_ids[]"
              value={w.id}
              checked={MapSet.member?(@panel.selected, w.id)}
              class="size-4 accent-brand"
            />
            <span class="text-body text-fg">{w.name}</span>
          </label>
        </.form>
        <:footer :let={cancel}>
          <span />
          <div class="flex items-center gap-2">
            <.button phx-click={cancel}>{dgettext("ui", "取消")}</.button>
            <.button
              id="daemon-panel-submit"
              type="submit"
              form={if(@panel && @panel.kind == :rename, do: "rename-form", else: "workspaces-form")}
              variant="primary"
            >
              {dgettext("ui", "保存")}
            </.button>
          </div>
        </:footer>
      </.side_panel>

      <.confirm_dialog
        id="runtimes-confirm"
        show={@confirm != nil}
        title={confirm_title(@confirm)}
        danger
        confirm_label={
          if(@confirm && @confirm.kind == :revoke,
            do: dgettext("ui", "吊销"),
            else: dgettext("ui", "禁用")
          )
        }
        on_confirm={if(@confirm && @confirm.kind == :revoke, do: "revoke", else: "disable")}
        confirm_value={if(@confirm, do: %{id: @confirm.id}, else: %{})}
        on_cancel={JS.push("dismiss")}
      >
        {confirm_text(@confirm)}
      </.confirm_dialog>
    </Layouts.app>
    """
  end

  attr :id, :string, required: true
  attr :text, :string, required: true

  defp command(assigns) do
    ~H"""
    <div class="flex items-center gap-2 rounded-field border border-border bg-raised px-3 py-2">
      <code id={"#{@id}-text"} class="min-w-0 flex-1 truncate font-mono text-label text-fg">{@text}</code>
      <.copy_button id={@id} text={@text} target={"##{@id}-text"} />
    </div>
    """
  end
end
