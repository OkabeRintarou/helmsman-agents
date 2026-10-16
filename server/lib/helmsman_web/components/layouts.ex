defmodule HelmsmanWeb.Layouts do
  @moduledoc """
  Application layouts.

  * `root.html.heex` — document skeleton; its inline script applies the theme,
    sidebar state and platform before the stylesheet loads (no flash of the wrong theme).
    It also holds `#hm-overlays`, the portal target of all modal layers (a sibling of
    `#hm-shell`).
  * `app/1` — workspace shell: sidebar + content surface with a page header slot.
  * `auth/1` — centered card for unauthenticated pages (no sidebar).
  * `personal/1` — the personal settings pages (no sidebar, tabs 账号 / 供应商账号).
  """
  use HelmsmanWeb, :html

  alias HelmsmanWeb.CommandPalette

  embed_templates "layouts/*"

  @doc """
  Workspace shell (spec web-app-shell): sidebar with workspace switcher, search entry,
  new-task entry, grouped navigation and user menu; a floating content surface with a
  48px page header (`:header` slot, usually `<.page_header>`) and the page body.

      <Layouts.app flash={@flash} current_scope={@current_scope} shell={@shell}>
        <:header><.page_header title="项目" /></:header>
        ...
      </Layouts.app>
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :current_scope, :map, default: nil, doc: "the current scope (user, workspace)"
  attr :shell, :map, default: nil, doc: "shell data assigned by HelmsmanWeb.Shell"

  attr :new_task, JS,
    default: nil,
    doc: "JS for the 新建任务 entry (defaults to adding ?panel=new to the current URL)"

  slot :header
  slot :inner_block, required: true

  def app(assigns) do
    shell =
      Map.merge(
        %{nav: [], workspaces: [], recent_tasks: [], path: nil, projects: []},
        assigns.shell || %{}
      )

    shell = Map.put_new(shell, :can_create_task?, true)
    workspace = assigns.current_scope && Map.get(assigns.current_scope, :workspace)
    user = assigns.current_scope && Map.get(assigns.current_scope, :user)

    assigns =
      assign(assigns,
        shell: shell,
        workspace: workspace,
        user: user,
        new_task: assigns.new_task || JS.patch(new_task_path(shell))
      )

    ~H"""
    <div id="hm-shell" phx-hook="Hotkeys" class="flex h-dvh overflow-hidden bg-shell text-fg">
      <a
        href="#hm-main"
        class="sr-only z-50 rounded-field bg-raised px-3 py-2 text-body text-fg shadow-popover focus:not-sr-only focus:fixed focus:top-2 focus:left-2"
      >
        {dgettext("ui", "跳到主要内容")}
      </a>
      <div
        id="hm-sidebar-backdrop"
        class="fixed inset-0 z-30 hidden bg-scrim lg:hidden"
        aria-hidden="true"
        phx-click={close_drawer()}
      />
      <aside
        id="hm-sidebar"
        aria-label={dgettext("ui", "主导航")}
        data-cancel={close_drawer()}
        class={[
          "hm-sidebar fixed inset-y-0 left-0 z-40 flex w-64 -translate-x-full flex-col gap-1 bg-shell px-2 py-2",
          "motion-safe:transition-transform motion-safe:duration-150 [&.hm-drawer-open]:translate-x-0",
          "lg:static lg:z-auto lg:w-60 lg:translate-x-0 lg:sidebar-collapsed:w-13"
        ]}
      >
        <div class="flex items-center gap-1">
          <.workspace_switcher workspace={@workspace} workspaces={@shell.workspaces} />
          <.icon_button
            icon="lucide-panel-left"
            label={dgettext("ui", "折叠侧栏")}
            size="sm"
            class="hidden lg:inline-flex lg:sidebar-collapsed:hidden"
            phx-click={JS.dispatch("hm:toggle-sidebar")}
          />
        </div>
        <.sidebar_action
          id="hm-search-entry"
          icon="lucide-search"
          label={dgettext("ui", "搜索")}
          phx-click={CommandPalette.open()}
        >
          <:kbd>
            <.kbd mod>K</.kbd>
          </:kbd>
        </.sidebar_action>
        <.sidebar_action
          :if={@shell.can_create_task?}
          id="hm-new-task"
          icon="lucide-square-pen"
          label={dgettext("ui", "新建任务")}
          data-hm-new-task
          phx-click={@new_task |> close_drawer()}
        >
          <:kbd>
            <.kbd>C</.kbd>
          </:kbd>
        </.sidebar_action>
        <nav
          aria-label={dgettext("ui", "页面")}
          class="mt-2 flex min-h-0 flex-1 flex-col gap-3 overflow-y-auto"
        >
          <div :for={group <- @shell.nav} id={"hm-nav-#{group.id}"} class="flex flex-col gap-px">
            <p class="hm-nav-label px-2 pb-1 text-micro font-medium text-fg-subtle lg:sidebar-collapsed:sr-only">
              {group.label}
            </p>
            <.nav_link :for={item <- group.items} item={item} />
          </div>
        </nav>
        <.icon_button
          icon="lucide-panel-left-open"
          label={dgettext("ui", "展开侧栏")}
          size="sm"
          class="hidden lg:sidebar-collapsed:inline-flex"
          phx-click={JS.dispatch("hm:toggle-sidebar")}
        />
        <.user_menu user={@user} avatar={@shell[:user_avatar] || %{}} />
      </aside>
      <div class="flex min-w-0 flex-1 flex-col lg:py-2 lg:pr-2">
        <div class="relative flex min-h-0 flex-1 flex-col overflow-hidden bg-canvas lg:rounded-box lg:border lg:border-border">
          {render_slot(@header)}
          <.import_notice :if={@shell[:import_notice]} uri={@shell[:uri]} />
          <main id="hm-main" tabindex="-1" class="min-h-0 flex-1 overflow-y-auto focus:outline-none">
            {render_slot(@inner_block)}
          </main>
          <.flash_group flash={@flash} />
        </div>
      </div>
    </div>
    <.live_component
      module={CommandPalette}
      id="command-palette"
      scope={@current_scope}
      shell={@shell}
    />
    <.live_component
      module={HelmsmanWeb.NewTaskPanel}
      id="new-task-panel"
      scope={@current_scope}
      shell={@shell}
    />
    """
  end

  defp new_task_path(%{uri: uri}) when is_binary(uri),
    do: HelmsmanWeb.Url.put_params(uri, %{panel: "new"})

  defp new_task_path(_shell), do: "?panel=new"

  attr :workspace, :map, default: nil
  attr :workspaces, :list, default: []

  defp workspace_switcher(assigns) do
    current = assigns.workspace && assigns.workspace.slug

    items =
      Enum.map(assigns.workspaces, fn ws ->
        %{
          id: "hm-ws-#{ws.slug}",
          label: ws.name,
          checked: ws.slug == current,
          on_select: JS.push("hm:switch-workspace", value: %{slug: ws.slug})
        }
      end) ++
        [
          %{type: :divider},
          %{
            id: "hm-ws-new",
            label: dgettext("ui", "新建工作区"),
            icon: "lucide-plus",
            navigate: "/workspaces/new"
          }
        ]

    assigns = assign(assigns, :items, items)

    ~H"""
    <.dropdown
      id="hm-workspace-switcher"
      items={@items}
      label={dgettext("ui", "切换工作区")}
      class="min-w-0 flex-1"
      trigger_class="h-8 w-full min-w-0 px-2 font-medium"
      popover_class="w-60"
    >
      <:trigger>
        <span class="inline-flex size-5 shrink-0 items-center justify-center rounded-badge bg-brand text-micro font-semibold text-on-brand">
          {initial(@workspace)}
        </span>
        <span class="truncate text-body lg:sidebar-collapsed:sr-only">
          {(@workspace && @workspace.name) || "Helmsman"}
        </span>
        <.icon
          name="lucide-chevrons-up-down"
          class="ml-auto size-3.5 text-fg-subtle lg:sidebar-collapsed:hidden"
        />
      </:trigger>
    </.dropdown>
    """
  end

  defp initial(nil), do: "H"
  defp initial(%{name: name}), do: name |> String.first() |> String.upcase()

  attr :id, :string, required: true
  attr :icon, :string, required: true
  attr :label, :string, required: true
  attr :rest, :global
  slot :kbd

  defp sidebar_action(assigns) do
    ~H"""
    <span class="hm-tooltip-host relative flex">
      <button
        id={@id}
        type="button"
        class="flex h-8 w-full items-center gap-2 rounded-field px-2 text-body text-fg-muted hover:bg-hover hover:text-fg"
        {@rest}
      >
        <.icon name={@icon} class="size-4 shrink-0" />
        <span class="truncate lg:sidebar-collapsed:sr-only">{@label}</span>
        <span class="ml-auto lg:sidebar-collapsed:hidden">{render_slot(@kbd)}</span>
      </button>
      <span role="tooltip" class={[tooltip_class(:right), "hidden lg:sidebar-collapsed:block"]}>
        {@label}
      </span>
    </span>
    """
  end

  attr :item, :map, required: true

  defp nav_link(assigns) do
    hint = assigns.item[:hint]
    full = if hint, do: "#{assigns.item.label}（#{hint}）", else: assigns.item.label
    assigns = assign(assigns, full: full, hint: hint)

    ~H"""
    <span class="hm-tooltip-host relative flex">
      <.link
        navigate={@item.path}
        aria-current={@item.current? && "page"}
        aria-label={@hint && @full}
        title={@hint && @full}
        phx-click={close_drawer()}
        class={[
          "flex h-8 w-full items-center gap-2 rounded-field px-2 text-body",
          if(@item.current?,
            do: "bg-selected font-medium text-fg",
            else: "text-fg-muted hover:bg-hover hover:text-fg"
          )
        ]}
      >
        <.icon name={@item.icon} class="size-4 shrink-0" />
        <span class="truncate lg:sidebar-collapsed:sr-only">{@item.label}</span>
        <span
          :if={@item.badge}
          class="ml-auto text-caption text-fg-subtle lg:sidebar-collapsed:hidden"
        >
          {@item.badge}
        </span>
      </.link>
      <span role="tooltip" class={[tooltip_class(:right), "hidden lg:sidebar-collapsed:block"]}>
        {@full}
      </span>
    </span>
    """
  end

  attr :user, :map, default: nil

  attr :avatar, :map,
    default: %{},
    doc: "`%{avatar_url, avatar_icon}` (`AvatarData.user_avatar/1`)"

  defp user_menu(%{user: nil} = assigns), do: ~H""

  defp user_menu(assigns) do
    user = assigns.user

    name =
      Map.get(user, :display_name) || Map.get(user, :name) || Map.get(user, :email) || ""

    theme_group = dgettext("ui", "主题")

    items = [
      %{
        id: "hm-account",
        label: dgettext("ui", "账号设置"),
        icon: "lucide-user-cog",
        navigate: "/users/settings"
      },
      %{
        id: "hm-provider-accounts",
        label: dgettext("ui", "供应商账号"),
        icon: "lucide-key-round",
        navigate: "/users/settings/provider-accounts"
      },
      %{
        id: "hm-mcp-servers",
        label: dgettext("ui", "我的 MCP 服务器"),
        icon: "lucide-plug",
        navigate: "/users/settings/mcp-servers"
      }
    ]

    admin_items =
      if Map.get(user, :instance_admin) == true do
        [
          %{
            id: "hm-instance-admin",
            label: dgettext("ui", "实例管理"),
            icon: "lucide-server-cog",
            navigate: "/admin/github"
          }
        ]
      else
        []
      end

    rest = [
      %{type: :divider},
      theme_item("system", dgettext("ui", "跟随系统"), "lucide-monitor", theme_group),
      theme_item("light", dgettext("ui", "亮"), "lucide-sun", theme_group),
      theme_item("dark", dgettext("ui", "暗"), "lucide-moon", theme_group),
      %{type: :divider},
      %{
        id: "hm-log-out",
        label: dgettext("ui", "退出登录"),
        icon: "lucide-log-out",
        href: "/users/log-out",
        method: "delete"
      }
    ]

    assigns = assign(assigns, name: name, items: items ++ admin_items ++ rest)

    ~H"""
    <.dropdown
      id="hm-user-menu"
      items={@items}
      label={dgettext("ui", "用户菜单")}
      placement={:top}
      class="w-full"
      trigger_class="h-9 w-full min-w-0 px-2"
      popover_class="w-56"
    >
      <:trigger>
        <.actor_mark actor={Map.merge(@avatar, %{name: @name, kind: :human})} />
        <span class="truncate text-body text-fg lg:sidebar-collapsed:sr-only">{@name}</span>
      </:trigger>
    </.dropdown>
    """
  end

  defp theme_item(theme, label, icon, group) do
    %{
      id: "hm-theme-#{theme}",
      group: group,
      label: label,
      icon: icon,
      checked: :client,
      attrs: %{"data-theme-option": theme},
      on_select: JS.dispatch("phx:set-theme", detail: %{theme: theme})
    }
  end

  @doc """
  Centered card layout for authentication pages (login, registration, confirmation,
  `/device`) and the account settings page, which lies outside any workspace.
  """
  attr :flash, :map, required: true
  attr :title, :string, default: nil
  slot :inner_block, required: true

  def auth(assigns) do
    ~H"""
    <div class="flex min-h-dvh flex-col items-center justify-center bg-shell px-4 py-12">
      <.link
        href="/"
        class="mb-6 flex items-center gap-2 rounded-field text-title font-semibold text-fg"
      >
        <span class="inline-flex size-7 items-center justify-center rounded-field bg-brand text-on-brand">
          <.icon name="lucide-ship-wheel" class="size-4" />
        </span>
        Helmsman
      </.link>
      <main
        id="hm-main"
        class="w-full max-w-[400px] rounded-box border border-border bg-surface p-6"
      >
        <h1 :if={@title} class="mb-4 text-heading font-semibold text-fg">{@title}</h1>
        {render_slot(@inner_block)}
      </main>
    </div>
    <div class="fixed right-4 bottom-4 z-[60]">
      <.flash_group flash={@flash} />
    </div>
    """
  end

  @doc """
  The personal settings pages (add-provider-accounts-ui D2): outside any workspace, no
  sidebar; a centered 960px surface with a "返回工作区" link and the user's name on top,
  the title 个人设置 and the tabs 账号 (`/users/settings`) and 供应商账号
  (`/users/settings/provider-accounts`).
  """
  attr :flash, :map, required: true
  attr :current_scope, :map, required: true
  attr :active, :atom, required: true, values: [:account, :provider_accounts, :mcp_servers]

  attr :avatar, :map,
    default: %{},
    doc: "the user's avatar `%{avatar_url, avatar_icon}` (`AvatarData.user_avatar/1`)"

  attr :class, :any, default: nil, doc: "classes of the content below the tabs"
  slot :inner_block, required: true

  def personal(assigns) do
    ~H"""
    <.settings_frame
      flash={@flash}
      current_scope={@current_scope}
      title={dgettext("ui", "个人设置")}
      avatar={@avatar}
      class={@class}
    >
      <:tab navigate="/users/settings" active={@active == :account}>
        {dgettext("ui", "账号")}
      </:tab>
      <:tab navigate="/users/settings/provider-accounts" active={@active == :provider_accounts}>
        {dgettext("ui", "供应商账号")}
      </:tab>
      <:tab navigate="/users/settings/mcp-servers" active={@active == :mcp_servers}>
        {dgettext("ui", "我的 MCP 服务器")}
      </:tab>
      {render_slot(@inner_block)}
    </.settings_frame>
    """
  end

  @doc """
  The instance administration pages (add-github-ui D14): the same frame as
  `personal/1`, titled 实例管理, with the single tab GitHub App
  (`/admin/github`).
  """
  attr :flash, :map, required: true
  attr :current_scope, :map, required: true
  attr :active, :atom, required: true, values: [:github]
  attr :class, :any, default: nil, doc: "classes of the content below the tabs"
  slot :inner_block, required: true

  def instance_admin(assigns) do
    ~H"""
    <.settings_frame
      flash={@flash}
      current_scope={@current_scope}
      title={dgettext("ui", "实例管理")}
      class={@class}
    >
      <:tab navigate="/admin/github" active={@active == :github}>
        {dgettext("ui", "GitHub App")}
      </:tab>
      {render_slot(@inner_block)}
    </.settings_frame>
    """
  end

  attr :flash, :map, required: true
  attr :current_scope, :map, required: true
  attr :title, :string, required: true
  attr :avatar, :map, default: %{}
  attr :class, :any, default: nil

  slot :tab, required: true do
    attr :navigate, :string, required: true
    attr :active, :boolean
  end

  slot :inner_block, required: true

  defp settings_frame(assigns) do
    user = assigns.current_scope.user

    assigns =
      assign(assigns, :name, Map.get(user, :display_name) || Map.get(user, :email) || "")

    ~H"""
    <div class="min-h-dvh bg-shell px-4 py-12">
      <div class="mx-auto flex w-full max-w-[960px] flex-col gap-4">
        <div class="flex items-center justify-between gap-4">
          <.link
            id="hm-back-to-workspace"
            href="/"
            class="flex items-center gap-2 rounded-field text-body text-fg-muted hover:text-fg"
          >
            <span class="inline-flex size-7 items-center justify-center rounded-field bg-brand text-on-brand">
              <.icon name="lucide-ship-wheel" class="size-4" />
            </span>
            <.icon name="lucide-arrow-left" class="size-4" />
            {dgettext("ui", "返回工作区")}
          </.link>
          <span id="hm-personal-user" class="flex min-w-0 items-center gap-2 text-body text-fg">
            <.actor_mark actor={Map.merge(@avatar, %{name: @name, kind: :human})} />
            <span class="truncate">{@name}</span>
          </span>
        </div>
        <main
          id="hm-main"
          class="w-full rounded-box border border-border bg-surface px-6 pt-5 pb-6"
        >
          <h1 class="text-heading font-semibold text-fg">{@title}</h1>
          <.tabs label={@title} class="mt-3 mb-6">
            <:tab :for={tab <- @tab} navigate={tab.navigate} active={tab[:active]}>
              {render_slot(tab)}
            </:tab>
          </.tabs>
          <div class={@class}>{render_slot(@inner_block)}</div>
        </main>
      </div>
    </div>
    <div class="fixed right-4 bottom-4 z-[60]">
      <.flash_group flash={@flash} />
    </div>
    """
  end

  # Shown after a committed import of the workspace (add-data-settings-ui D11).
  attr :uri, :string, default: nil

  defp import_notice(assigns) do
    ~H"""
    <div
      id="hm-import-notice"
      role="status"
      class="flex flex-none items-center gap-3 border-b border-border tint-info px-4 py-2 text-body text-info-fg"
    >
      <.icon name="lucide-database-backup" class="size-4 shrink-0" />
      <span class="min-w-0 flex-1">{dgettext("ui", "工作区数据已被导入更新，当前页面可能已过期")}</span>
      <.link
        :if={@uri}
        id="hm-import-notice-reload"
        navigate={@uri}
        class="rounded-field font-medium underline-offset-2 hover:underline"
      >
        {dgettext("ui", "刷新")}
      </.link>
      <.icon_button
        id="hm-import-notice-dismiss"
        icon="lucide-x"
        size="sm"
        label={dgettext("ui", "关闭")}
        phx-click="hm:dismiss-import-notice"
      />
    </div>
    """
  end

  @doc """
  Flash notices in the bottom-right corner of the content surface.
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div
      id={@id}
      class="pointer-events-none absolute right-4 bottom-4 z-[60] flex flex-col items-end gap-2"
    >
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title={dgettext("ui", "无法连接到服务器")}
        phx-disconnected={show(".phx-client-error #client-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {dgettext("ui", "正在重新连接")}
        <.icon name="lucide-loader-circle" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title={dgettext("ui", "出了点问题")}
        phx-disconnected={show(".phx-server-error #server-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {dgettext("ui", "正在重新连接")}
        <.icon name="lucide-loader-circle" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end

  @doc """
  Segmented theme switch (跟随系统 / 亮 / 暗) for pages without the user menu.
  The active option is highlighted by CSS from `<html data-theme-pref>`.
  """
  def theme_toggle(assigns) do
    assigns =
      assign(assigns, :options, [
        {"system", "lucide-monitor", dgettext("ui", "跟随系统")},
        {"light", "lucide-sun", dgettext("ui", "亮")},
        {"dark", "lucide-moon", dgettext("ui", "暗")}
      ])

    ~H"""
    <div
      role="group"
      aria-label={dgettext("ui", "主题")}
      class="inline-flex items-center gap-0.5 rounded-field border border-border bg-surface p-0.5"
    >
      <button
        :for={{theme, icon, label} <- @options}
        type="button"
        data-theme-option={theme}
        aria-label={label}
        title={label}
        class="hm-theme-option inline-flex size-6 items-center justify-center rounded-badge text-fg-muted hover:text-fg"
        phx-click={JS.dispatch("phx:set-theme", detail: %{theme: theme})}
      >
        <.icon name={icon} class="size-3.5" />
      </button>
    </div>
    """
  end

  @doc false
  def title_suffix(assigns) do
    case assigns[:current_scope] do
      %{workspace: %{name: name}} -> " · #{name}"
      _ -> " · Helmsman"
    end
  end
end
