defmodule HelmsmanWeb.SettingsLive.GitHub do
  @moduledoc """
  GitHub settings `/w/:slug/settings/github` (add-github-ui D3–D5, D13; spec web-github
  GitHub 设置页 / 断开 GitHub / 仓库列表 / GitHub 设置页实时刷新).

  * The connection card shows one of five states (not configured, not connected,
    connected, suspended, disconnected). 连接 GitHub / 重新连接 are plain links to the
    controller route that redirects to GitHub.
  * 断开 asks for confirmation; owners and admins only (events from other roles are
    refused here too, and the domain checks the role again).
  * The repository table lists `GitHub.status/1`'s repositories plus the repositories
    bound by a project that the status no longer lists (a disconnect or a removal from
    the installation marks them removed), so a binding stays visible as 不可用. Each
    row shows the projects bound to it.
  * `{:github_changed}` and `{:projects_changed}` (forwarded by the shell) re-read
    everything; an open confirmation dialog stays open.
  """
  use HelmsmanWeb, :live_view

  import HelmsmanWeb.SettingsComponents
  import HelmsmanWeb.GitHubComponents, only: [repository_url: 1]

  alias Helmsman.{GitHub, Policy, Projects}

  @filter_threshold 10

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope

    {:ok,
     socket
     |> assign(
       page_title: "GitHub",
       can_manage?: Policy.authorize(scope, :manage_github) == :ok,
       instance_admin?: Policy.authorize(scope, :manage_github_app) == :ok,
       confirm: false,
       query: ""
     )
     |> stream_configure(:repositories, dom_id: &"repository-#{&1.id}")
     |> load()}
  end

  defp load(socket) do
    scope = socket.assigns.current_scope
    {:ok, status} = GitHub.status(scope)

    projects =
      case Projects.list(scope, include_archived: true) do
        {:ok, projects} -> projects
        {:error, _} -> []
      end

    rows = rows(status, projects)

    socket
    |> assign(status: status, rows: rows, bound: Enum.group_by(projects, & &1.repository_id))
    |> show_rows()
  end

  defp rows(%{installation: nil}, _projects), do: []

  defp rows(%{repositories: repositories}, projects) do
    listed = MapSet.new(repositories, & &1.id)

    bound =
      projects
      |> Enum.map(& &1.repository)
      |> Enum.reject(&(&1 == nil or MapSet.member?(listed, &1.id)))
      |> Enum.uniq_by(& &1.id)
      |> Enum.map(fn repository ->
        %{
          id: repository.id,
          full_name: repository.full_name,
          default_branch: nil,
          private: false,
          available: repository.available
        }
      end)

    Enum.sort_by(repositories ++ bound, &String.downcase(&1.full_name))
  end

  defp show_rows(socket) do
    %{rows: rows, query: query} = socket.assigns
    q = query |> String.trim() |> String.downcase()

    shown =
      if q == "",
        do: rows,
        else: Enum.filter(rows, &String.contains?(String.downcase(&1.full_name), q))

    socket
    |> assign(shown_count: length(shown))
    |> stream(:repositories, shown, reset: true)
  end

  @impl true
  def handle_event("filter", %{"q" => query}, socket),
    do: {:noreply, socket |> assign(:query, query) |> show_rows()}

  def handle_event("ask_disconnect", _params, socket) do
    if socket.assigns.can_manage?,
      do: {:noreply, assign(socket, :confirm, true)},
      else: {:noreply, forbidden(socket, :disconnect)}
  end

  def handle_event("dismiss", _params, socket), do: {:noreply, assign(socket, :confirm, false)}

  def handle_event("disconnect", _params, socket) do
    socket = assign(socket, :confirm, false)

    if socket.assigns.can_manage? do
      {:noreply, socket |> disconnect() |> load()}
    else
      {:noreply, forbidden(socket, :disconnect)}
    end
  end

  def handle_event("resync", _params, socket) do
    if socket.assigns.can_manage? do
      {:noreply, resync(socket)}
    else
      {:noreply, forbidden(socket)}
    end
  end

  defp disconnect(socket) do
    case GitHub.disconnect_installation(socket.assigns.current_scope) do
      {:ok, _installation} -> put_flash(socket, :info, dgettext("ui", "已断开 GitHub"))
      {:error, :not_found} -> put_flash(socket, :info, dgettext("ui", "GitHub 已经断开"))
      {:error, _reason} -> forbidden(socket, :disconnect)
    end
  end

  defp resync(socket) do
    case GitHub.request_sync(socket.assigns.current_scope) do
      :ok ->
        put_flash(socket, :info, dgettext("ui", "已开始同步仓库"))

      {:error, :not_found} ->
        socket |> put_flash(:error, dgettext("ui", "工作区没有连接 GitHub")) |> load()

      {:error, _reason} ->
        forbidden(socket)
    end
  end

  defp forbidden(socket, action \\ :manage)

  defp forbidden(socket, :disconnect),
    do: put_flash(socket, :error, dgettext("ui", "只有工作区的所有者或管理员可以断开 GitHub"))

  defp forbidden(socket, :manage),
    do: put_flash(socket, :error, dgettext("ui", "只有工作区的所有者或管理员可以管理 GitHub"))

  @impl true
  def handle_info({:github_changed}, socket), do: {:noreply, load(socket)}
  def handle_info({:projects_changed}, socket), do: {:noreply, load(socket)}
  def handle_info(_message, socket), do: {:noreply, socket}

  ## Rendering

  defp connection(%{configured?: false}), do: :not_configured
  defp connection(%{installation: nil}), do: :not_connected
  defp connection(%{installation: %{disconnected?: true}}), do: :disconnected
  defp connection(%{installation: %{suspended?: true}}), do: :suspended
  defp connection(_status), do: :connected

  defp account_type("Organization"), do: dgettext("ui", "组织")
  defp account_type(_type), do: dgettext("ui", "个人账号")

  defp settings_url(%{installation: %{settings_url: url}}), do: url
  defp settings_url(_status), do: nil

  @impl true
  def render(assigns) do
    slug = assigns.current_scope.workspace.slug

    assigns =
      assign(assigns,
        slug: slug,
        state: connection(assigns.status),
        connect_path: "/w/#{slug}/settings/github/connect",
        settings_url: settings_url(assigns.status),
        installation: assigns.status.installation
      )

    ~H"""
    <.settings_page tab={:github} flash={@flash} current_scope={@current_scope} shell={@shell}>
      <section
        id="github-connection"
        aria-labelledby="github-connection-title"
        data-state={@state}
        class="mb-8 flex flex-col gap-4 rounded-box border border-border bg-surface p-4 sm:flex-row sm:items-start"
      >
        <span class="flex size-10 flex-none items-center justify-center rounded-field bg-hover">
          <.icon name="lucide-git-branch" class="size-5 text-fg-muted" />
        </span>
        <div class="flex min-w-0 flex-1 flex-col gap-1">
          <.connection_body
            state={@state}
            status={@status}
            installation={@installation}
            can_manage?={@can_manage?}
            instance_admin?={@instance_admin?}
            settings_url={@settings_url}
          />
        </div>
        <div :if={@can_manage?} class="flex flex-none items-center gap-2">
          <.button
            :if={@state == :not_connected}
            id="github-connect"
            variant="primary"
            href={@connect_path}
          >
            {dgettext("ui", "连接 GitHub")}
          </.button>
          <.button
            :if={@state == :disconnected}
            id="github-reconnect"
            variant="primary"
            href={@connect_path}
          >
            {dgettext("ui", "重新连接")}
          </.button>
          <.button
            :if={@state in [:connected, :suspended]}
            id="github-disconnect"
            phx-click="ask_disconnect"
          >
            {dgettext("ui", "断开")}
          </.button>
        </div>
      </section>

      <.settings_section
        :if={@installation}
        id="github-repositories"
        title={dgettext("ui", "仓库")}
      >
        <:actions>
          <.button
            :if={@can_manage? and @state in [:connected, :suspended]}
            id="github-resync"
            size="sm"
            icon="lucide-refresh-cw"
            phx-click="resync"
          >
            {dgettext("ui", "重新同步")}
          </.button>
        </:actions>
        <form
          :if={length(@rows) > repository_filter_threshold()}
          id="github-repositories-filter"
          phx-change="filter"
          phx-submit="filter"
          class="mb-3"
        >
          <.input
            id="github-repositories-q"
            name="q"
            type="search"
            value={@query}
            placeholder={dgettext("ui", "按名称筛选仓库")}
            aria-label={dgettext("ui", "按名称筛选仓库")}
            autocomplete="off"
            phx-debounce="150"
          />
        </form>
        <.data_table
          id="repositories"
          class={@shown_count == 0 && "hidden"}
          rows={@streams.repositories}
          label={dgettext("ui", "仓库")}
        >
          <:col :let={r} label={dgettext("ui", "仓库")}>
            <span class="flex min-w-0 items-center gap-1.5">
              <a
                href={repository_url(r.full_name)}
                target="_blank"
                rel="noopener noreferrer"
                class="truncate font-mono text-fg hover:underline"
                data-name
              >
                {r.full_name}
              </a>
              <.badge :if={r.private} data-private>{dgettext("ui", "私有")}</.badge>
              <.badge :if={r[:archived]} tone={:warning} data-archived>
                {dgettext("ui", "已归档")}
              </.badge>
            </span>
          </:col>
          <:col :let={r} label={dgettext("ui", "默认分支")} secondary class="w-36">
            <span class="truncate font-mono text-label text-fg-muted" data-default-branch>
              {r.default_branch || "—"}
            </span>
          </:col>
          <:col :let={r} label={dgettext("ui", "状态")} class="w-20 md:w-24">
            <.badge :if={r.available} tone={:success} data-available>{dgettext("ui", "可用")}</.badge>
            <.tooltip
              :if={!r.available}
              id={"repository-#{r.id}-unavailable"}
              text={dgettext("ui", "安装已断开、已暂停，或仓库已移出安装范围")}
            >
              <.badge data-unavailable>{dgettext("ui", "不可用")}</.badge>
            </.tooltip>
          </:col>
          <:col :let={r} label={dgettext("ui", "项目")} class="w-28 md:w-48">
            <span class="flex flex-wrap items-center gap-1" data-projects>
              <.link
                :for={p <- Map.get(@bound, r.id, [])}
                navigate={"/w/#{@slug}/p/#{p.key}"}
                data-project={p.key}
                data-archived={p.archived_at && "true"}
                class={[
                  "rounded-badge bg-hover px-1.5 font-mono text-caption hover:text-fg",
                  if(p.archived_at, do: "text-fg-subtle", else: "text-fg-muted")
                ]}
              >
                {p.key}
              </.link>
              <span :if={Map.get(@bound, r.id, []) == []} class="text-fg-subtle">—</span>
            </span>
          </:col>
        </.data_table>
        <p
          :if={@rows != [] and @shown_count == 0}
          id="github-repositories-no-match"
          class="py-4 text-center text-body text-fg-muted"
        >
          {dgettext("ui", "没有符合条件的仓库")}
        </p>
        <div :if={@rows == []} id="github-repositories-empty">
          <.empty_state
            icon="lucide-folder-git-2"
            title={
              if(@state == :disconnected,
                do: dgettext("ui", "没有仓库"),
                else: dgettext("ui", "安装没有授权任何仓库")
              )
            }
          >
            <:action :if={@can_manage? and @settings_url != nil and @state != :disconnected}>
              <a
                href={@settings_url}
                target="_blank"
                rel="noopener noreferrer"
                class="text-body text-brand-fg hover:underline"
              >
                {dgettext("ui", "在 GitHub 上管理仓库访问")}
              </a>
            </:action>
          </.empty_state>
        </div>
      </.settings_section>

      <.confirm_dialog
        :if={@can_manage? and @installation != nil}
        id="disconnect-github-dialog"
        show={@confirm}
        title={dgettext("ui", "断开 GitHub？")}
        danger
        confirm_label={dgettext("ui", "断开")}
        on_confirm="disconnect"
        on_cancel={JS.push("dismiss")}
      >
        {dgettext(
          "ui",
          "只解除本工作区与安装 %{account} 的关联，不会在 GitHub 上卸载 App。断开后仓库变为不可用：不再开 PR、不再合并，Agent 无法推送；项目的仓库绑定保留，重新连接同一安装即恢复。",
          account: @installation && @installation.account_login
        )}
      </.confirm_dialog>
    </.settings_page>
    """
  end

  defp repository_filter_threshold, do: @filter_threshold

  attr :state, :atom, required: true
  attr :status, :map, required: true
  attr :installation, :map, default: nil
  attr :can_manage?, :boolean, required: true
  attr :instance_admin?, :boolean, required: true
  attr :settings_url, :string, default: nil

  defp connection_body(%{state: :not_configured} = assigns) do
    ~H"""
    <h2 id="github-connection-title" class="text-title font-semibold text-fg">
      {dgettext("ui", "GitHub 未配置")}
    </h2>
    <p class="text-body text-fg-muted">{dgettext("ui", "实例管理员需要先创建 GitHub App")}</p>
    <.link
      :if={@instance_admin?}
      id="github-admin-link"
      href="/admin/github"
      class="text-body text-brand-fg hover:underline"
    >
      {dgettext("ui", "前往实例管理")}
    </.link>
    """
  end

  defp connection_body(%{state: :not_connected} = assigns) do
    ~H"""
    <h2 id="github-connection-title" class="text-title font-semibold text-fg">
      {dgettext("ui", "连接 GitHub")}
    </h2>
    <p class="text-body text-fg-muted">
      {dgettext(
        "ui",
        "安装 Helmsman 的 GitHub App 并选择仓库，Agent 的提交将以 PR 交付，验收后自动合并"
      )}
    </p>
    <p :if={!@can_manage?} id="github-ask-admin" class="text-body text-fg-muted">
      {dgettext("ui", "请工作区的所有者或管理员连接")}
    </p>
    """
  end

  defp connection_body(assigns) do
    ~H"""
    <h2 id="github-connection-title" class="flex flex-wrap items-center gap-2 text-title text-fg">
      <span class="font-semibold" id="github-account">{@installation.account_login}</span>
      <span class="text-body text-fg-muted" id="github-account-type">
        {account_type(@installation.account_type)}
      </span>
      <.badge :if={@state == :connected} tone={:success} id="github-badge">
        {dgettext("ui", "已连接")}
      </.badge>
      <.badge :if={@state == :suspended} tone={:warning} id="github-badge">
        {dgettext("ui", "已在 GitHub 上暂停")}
      </.badge>
      <.badge :if={@state == :disconnected} id="github-badge">{dgettext("ui", "已断开")}</.badge>
    </h2>
    <p
      :if={(@state != :disconnected and @status.app) && @status.app.name}
      class="text-body text-fg-muted"
      id="github-app"
    >
      {dgettext("ui", "GitHub App：%{name}", name: @status.app.name)}
    </p>
    <p :if={@state == :suspended} class="text-body text-warning-fg" id="github-suspended-note">
      {dgettext("ui", "暂停期间仓库不可用，在 GitHub 上恢复后自动可用")}
    </p>
    <p :if={@state == :disconnected} class="text-body text-fg-muted" id="github-disconnected-note">
      {dgettext("ui", "项目的仓库绑定已保留，重新连接同一安装即恢复")}
    </p>
    <a
      :if={@settings_url && @state != :disconnected}
      id="github-manage-access"
      href={@settings_url}
      target="_blank"
      rel="noopener noreferrer"
      class="inline-flex items-center gap-1 text-body text-brand-fg hover:underline"
    >
      {dgettext("ui", "在 GitHub 上管理仓库访问")}
      <.icon name="lucide-external-link" class="size-3.5" />
    </a>
    """
  end
end
