defmodule HelmsmanWeb.Dev.UiLive do
  @moduledoc """
  `/dev/ui` — component showcase (dev and test only, behind `dev_routes`).

  Lists every base component with its variants and states, all task / run status
  badges, the icons in use, color and type tokens and the contrast table of the
  current theme. It also hosts the shell tests: `:demo_scope` provides a fake user with
  the workspaces acme and beta plus demo navigation items.
  """
  use HelmsmanWeb, :live_view

  alias HelmsmanWeb.Components.Status
  alias HelmsmanWeb.Dev.ThemeTokens
  alias HelmsmanWeb.Filters
  alias HelmsmanWeb.Url

  @filter_schema [
    status: {:list, Status.task_statuses()},
    label: :list,
    q: :string
  ]

  @doc """
  `on_mount` providing a demo scope. Tests may set `"dev_ui_user_id"` in the session to
  isolate PubSub topics and `"dev_ui_workspaces"` (slugs) to limit the workspace list.
  """
  def on_mount(:demo_scope, _params, session, socket) do
    acme = %{id: "ws-acme", slug: "acme", name: "acme"}
    beta = %{id: "ws-beta", slug: "beta", name: "beta"}

    scope = %{
      user: %{
        id: session["dev_ui_user_id"] || "demo-user",
        name: "Alice",
        email: "alice@example.com"
      },
      workspace: acme,
      workspaces:
        Enum.filter(
          [acme, beta],
          &(&1.slug in (session["dev_ui_workspaces"] || ["acme", "beta"]))
        ),
      role: :member
    }

    {:cont,
     Phoenix.Component.assign(socket,
       current_scope: scope,
       shell_nav_items: demo_nav_items()
     )}
  end

  defp demo_nav_items do
    [
      %{
        id: :showcase,
        group: :my_work,
        label: fn -> dgettext("ui", "组件陈列") end,
        icon: "lucide-layout-grid",
        path: fn _ -> "/dev/ui" end
      },
      %{
        id: :projects,
        group: :projects,
        label: fn -> dgettext("ui", "查看全部") end,
        icon: "lucide-folder",
        path: fn _ -> "/dev/ui/projects" end
      },
      %{
        id: :squads,
        group: :agents,
        label: fn -> dgettext("ui", "小队") end,
        icon: "lucide-users",
        path: fn _ -> "/dev/ui/squads" end,
        visible?: fn _ -> false end
      }
    ]
  end

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(
        loaded: 0,
        bumps: 0,
        panel_form: to_form(%{"title" => "", "note" => ""}, as: :task),
        demo_form: to_form(%{"title" => "", "note" => ""}, as: :demo),
        panel_error: nil,
        panel_dirty: false,
        confirmed: nil,
        guard_submits: 0,
        menu_selected: nil
      )
      |> stream_configure(:rows, dom_id: &"row-#{&1.id}")
      |> stream(:rows, [])
      |> load_rows()

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    title =
      if socket.assigns.live_action == :projects,
        do: dgettext("ui", "项目"),
        else: dgettext("ui", "组件陈列")

    {:noreply,
     assign(socket,
       page_title: title,
       params: params,
       tab: params["tab"] || "components",
       filters: Filters.parse(params, @filter_schema)
     )}
  end

  @impl true
  def handle_event("load_more", _params, socket), do: {:noreply, load_rows(socket)}

  def handle_event("bump_row", _params, socket) do
    bumps = socket.assigns.bumps + 1

    row = %{
      id: 1,
      ident: "BOS-1",
      title: "更新后的标题 #{bumps}",
      status: "in_progress",
      version: bumps
    }

    {:noreply, socket |> assign(:bumps, bumps) |> stream_insert(:rows, row)}
  end

  def handle_event("search", params, socket) do
    filters = Map.put(socket.assigns.filters, :q, String.trim(params["q"] || ""))

    {:noreply,
     push_patch(socket,
       to: Filters.path(base_path(socket), Map.reject(filters, &(elem(&1, 1) == "")))
     )}
  end

  def handle_event("validate_demo", %{"demo" => demo}, socket) do
    {:noreply, assign(socket, :demo_form, to_form(demo, as: :demo))}
  end

  def handle_event("validate_panel", %{"task" => task}, socket) do
    dirty = Enum.any?(task, fn {_, v} -> String.trim(v) != "" end)
    {:noreply, assign(socket, panel_form: to_form(task, as: :task), panel_dirty: dirty)}
  end

  def handle_event("save_panel", %{"task" => task}, socket) do
    if String.trim(task["title"] || "") == "" do
      errors = [title: {"can't be blank", [validation: :required]}]

      {:noreply,
       assign(socket,
         panel_form: to_form(task, as: :task, errors: errors, action: :insert),
         panel_error: dgettext("ui", "保存失败：请检查标题。")
       )}
    else
      {:noreply,
       socket
       |> assign(
         panel_form: to_form(%{"title" => "", "note" => ""}, as: :task),
         panel_error: nil,
         panel_dirty: false
       )
       |> put_flash(:info, dgettext("ui", "已保存"))
       |> push_patch(to: Url.drop_params(socket.assigns.shell.uri, ["panel"]))}
    end
  end

  def handle_event("guard_submit", _params, socket) do
    {:noreply, update(socket, :guard_submits, &(&1 + 1))}
  end

  def handle_event("confirm", params, socket) do
    {:noreply, assign(socket, :confirmed, params["start"] || "true")}
  end

  def handle_event("menu_select", %{"item" => item}, socket) do
    {:noreply, assign(socket, :menu_selected, item)}
  end

  def handle_event("flash_error", _params, socket) do
    {:noreply, put_flash(socket, :error, dgettext("ui", "操作失败：这是一条错误提示"))}
  end

  def handle_event("flash_info", _params, socket) do
    {:noreply, put_flash(socket, :info, dgettext("ui", "已保存"))}
  end

  defp base_path(%{assigns: %{live_action: :projects}}), do: "/dev/ui/projects"
  defp base_path(_socket), do: "/dev/ui"

  defp load_rows(socket) do
    from = socket.assigns.loaded + 1
    to = min(from + 4, 15)

    rows =
      for id <- from..to//1 do
        status = Enum.at(Status.task_statuses(), rem(id, 6))
        %{id: id, ident: "BOS-#{id}", title: "示例任务 #{id}", status: status, version: 0}
      end

    socket |> assign(:loaded, to) |> stream(:rows, rows)
  end

  @impl true
  def render(assigns) do
    uri = assigns.shell.uri || base_path(%{assigns: assigns})

    assigns =
      assign(assigns,
        base: base_path(%{assigns: assigns}),
        panel_href: Url.put_params(uri, %{panel: "new"}),
        modal_href: Url.put_params(uri, %{modal: "log"}),
        close_href: Url.drop_params(uri, ~w(panel modal)),
        now: DateTime.utc_now()
      )

    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      shell={@shell}
      new_task={JS.patch(@panel_href)}
    >
      <:header>
        <.page_header title={@page_title}>
          <:crumb navigate="/dev/ui">Dev</:crumb>
          <:actions>
            <Layouts.theme_toggle />
            <.button variant="primary" icon="lucide-plus" patch={@panel_href}>
              {dgettext("ui", "新建任务")}
              <:kbd>
                <.kbd>C</.kbd>
              </:kbd>
            </.button>
          </:actions>
        </.page_header>
      </:header>

      <div class="flex flex-col gap-10 px-6 py-6">
        <.section id="buttons" title={dgettext("ui", "按钮")}>
          <div :for={size <- ~w(xs sm md lg)} class="flex flex-wrap items-center gap-2">
            <.button
              :for={variant <- ~w(primary secondary ghost danger link)}
              variant={variant}
              size={size}
            >
              {variant} {size}
            </.button>
            <.icon_button icon="lucide-ellipsis" label={dgettext("ui", "更多操作")} size={size} />
          </div>
          <div class="flex flex-wrap items-center gap-2">
            <.button icon="lucide-play">{dgettext("ui", "带图标")}</.button>
            <.button id="demo-disabled" disabled_reason={dgettext("ui", "只有成员可以开始任务")}>
              {dgettext("ui", "禁用并说明原因")}
            </.button>
            <.button disabled>{dgettext("ui", "禁用")}</.button>
            <.button variant="primary" class="phx-submit-loading">{dgettext("ui", "提交中")}</.button>
          </div>
        </.section>

        <.section id="forms" title={dgettext("ui", "表单控件")}>
          <.form
            for={@demo_form}
            id="demo-form"
            class="grid max-w-xl gap-3"
            phx-change="validate_demo"
          >
            <.input
              field={@demo_form[:title]}
              label={dgettext("ui", "标题")}
              help={dgettext("ui", "一句话说明要做什么")}
            />
            <.input field={@demo_form[:note]} type="textarea" label={dgettext("ui", "说明")} />
            <.input
              name="demo_select"
              type="select"
              value="b"
              label={dgettext("ui", "选择")}
              options={[{"A", "a"}, {"B", "b"}]}
            />
            <.input name="demo_check" type="checkbox" value="true" label={dgettext("ui", "复选框")} />
            <.input
              name="demo_switch"
              type="switch"
              value="false"
              label={dgettext("ui", "开关")}
              layout={:row}
            />
            <.input
              name="demo_radio"
              type="radio"
              value="b"
              label={dgettext("ui", "单选")}
              options={[{"A", "a"}, {"B", "b"}]}
            />
            <.input
              name="demo_row"
              value=""
              label={dgettext("ui", "行式布局")}
              layout={:row}
              errors={[dgettext("ui", "不能为空")]}
            />
          </.form>
        </.section>

        <.section id="guard" title={dgettext("ui", "禁用提交")}>
          <form id="demo-guard-form" phx-submit="guard_submit" class="flex items-end gap-2">
            <.input id="demo-guard-input" name="guard" value="" label={dgettext("ui", "名称")} />
            <.button
              id="demo-guard-submit"
              type="submit"
              variant="primary"
              disabled_reason={dgettext("ui", "只读成员不能保存")}
            >
              {dgettext("ui", "保存")}
            </.button>
          </form>
          <p id="demo-guard-count" class="text-label text-fg-muted">submitted: {@guard_submits}</p>
        </.section>

        <.section id="overlays" title={dgettext("ui", "弹层")}>
          <div class="flex flex-wrap items-center gap-2">
            <.button patch={@panel_href}>{dgettext("ui", "右侧面板（?panel=new）")}</.button>
            <.button patch={@modal_href}>{dgettext("ui", "弹窗（?modal=log）")}</.button>
            <.button
              variant="danger"
              phx-click={open_overlay("demo-confirm", focus: "#demo-confirm-cancel")}
            >
              {dgettext("ui", "吊销")}
            </.button>
            <.button phx-click={open_overlay("demo-start", focus: "#demo-start-confirm")}>
              {dgettext("ui", "开始任务…")}
            </.button>
            <span :if={@confirmed} id="demo-confirmed" class="text-label text-fg-muted">
              confirmed: {@confirmed}
            </span>
          </div>
        </.section>

        <.section id="menus" title={dgettext("ui", "菜单")}>
          <div class="flex flex-wrap items-center gap-4">
            <.dropdown
              id="demo-menu"
              label={dgettext("ui", "更多操作")}
              items={demo_menu_items()}
              trigger_class="h-8 px-2 border border-border-strong"
            >
              <:trigger>
                {dgettext("ui", "操作")}<.icon name="lucide-chevron-down" class="size-3.5" />
              </:trigger>
            </.dropdown>
            <.dropdown
              id="demo-long-menu"
              label={dgettext("ui", "负责人")}
              items={long_menu_items()}
              trigger_class="h-8 px-2 border border-border-strong"
            >
              <:trigger>{dgettext("ui", "负责人（12 项）")}</:trigger>
            </.dropdown>
            <span :if={@menu_selected} class="text-label text-fg-muted">selected: {@menu_selected}</span>
            <.tooltip id="demo-tooltip" text={dgettext("ui", "同步中")}>
              <.icon_button
                icon="lucide-refresh-cw"
                label={dgettext("ui", "同步")}
                tooltip={false}
                aria-describedby="demo-tooltip"
              />
            </.tooltip>
          </div>
        </.section>

        <.section id="tabs" title={dgettext("ui", "标签页")}>
          <.tabs label={dgettext("ui", "示例标签")}>
            <:tab patch={"#{@base}?tab=components"} active={@tab == "components"} count={12}>
              {dgettext("ui", "组件")}
            </:tab>
            <:tab patch={"#{@base}?tab=tokens"} active={@tab == "tokens"}>
              {dgettext("ui", "Token")}
            </:tab>
          </.tabs>
          <p id="tab-content" class="text-body text-fg-muted">tab: {@tab}</p>
        </.section>

        <.section id="status" title={dgettext("ui", "状态")}>
          <div class="flex flex-wrap items-center gap-2">
            <.status_badge :for={status <- Status.task_statuses()} status={status} />
            <.status_badge status="bogus" />
          </div>
          <div class="flex flex-wrap items-center gap-3">
            <.status_icon
              :for={status <- Status.task_statuses()}
              id={"icon-#{status}"}
              status={status}
            />
          </div>
          <div class="flex flex-wrap items-center gap-2">
            <.run_status_badge :for={status <- Status.run_statuses()} status={status} />
          </div>
          <div class="flex flex-wrap items-center gap-3">
            <.priority_icon :for={p <- ~w(low medium high)} priority={p} />
            <.badge :for={tone <- ~w(brand success warning danger info review muted)a} tone={tone}>
              {tone}
            </.badge>
          </div>
        </.section>

        <.section id="identity" title={dgettext("ui", "身份")}>
          <div class="flex flex-wrap items-center gap-4">
            <.actor_chip actor={%{name: "alice", kind: :human}} presence={:online} />
            <.actor_chip
              id="demo-agent"
              actor={%{name: "keel/dev", kind: :agent, owner_name: "alice", managed?: true}}
              presence={:busy}
            />
            <.actor_chip
              actor={%{name: "keel/reviewer", kind: :agent, owner_name: "bob", managed?: false}}
              compact
            />
            <.actor_chip actor={%{name: "core", kind: :squad}} />
            <.actor_chip actor={%{name: "system", kind: :system}} />
            <.actor_chip
              actor={%{name: "keel/dev", kind: :agent, owner_name: "alice"}}
              disabled_reason={dgettext("ui", "你无权触发 keel/dev")}
            />
            <.actor_chip actor={%{name: "old", kind: :agent, state: :archived}} />
            <.presence_dot :for={s <- [:online, :busy, :offline]} status={s} />
            <.working_chip id="demo-working" agents={["keel/dev", "keel/reviewer"]} />
          </div>
        </.section>

        <.section id="text" title={dgettext("ui", "文本")}>
          <div class="flex flex-wrap items-center gap-4">
            <.task_id_link ident="BOS-12" workspace="acme" title="实现命令面板" />
            <.task_id_link ident="BOS-7" workspace="acme" status="CANCELLED" />
            <.relative_time id="demo-time" at={DateTime.add(@now, -180)} now={@now} />
            <span><.kbd mod>K</.kbd>

            <.kbd>C</.kbd>

            <.kbd>[</.kbd></span>
            <.copy_button id="demo-copy" text="mix helmsman.check_ui_classes" />
          </div>
          <.secret_once id="demo-secret" value="hm_live_1234567890abcdef" class="max-w-lg" />
          <.spark_bars label={dgettext("ui", "近 14 天运行次数")} points={spark_points(@now)} />
          <.spark_bars
            label={dgettext("ui", "全零数据")}
            points={Enum.map(spark_points(@now), &{elem(&1, 0), 0})}
          />
        </.section>

        <.section id="layout" title={dgettext("ui", "布局")}>
          <.property_list class="max-w-md">
            <.property_row label={dgettext("ui", "负责人")}>
              <.actor_chip actor={%{name: "alice", kind: :human}} />
            </.property_row>
            <.property_row label={dgettext("ui", "截止日期")} value={nil} editable />
            <.property_row label={dgettext("ui", "标签")} value="api" />
          </.property_list>
          <div class="grid gap-4 md:grid-cols-2">
            <div class="rounded-box border border-border bg-surface">
              <.empty_state description={dgettext("ui", "创建第一个任务开始吧")}>
                <:action>
                  <.button variant="primary" patch={@panel_href}>{dgettext("ui", "新建任务")}</.button>
                </:action>
              </.empty_state>
            </div>
            <div class="rounded-box border border-border bg-surface">
              <.empty_state kind={:filtered} on_clear={JS.patch(@base)} />
            </div>
          </div>
        </.section>

        <.section id="table" title={dgettext("ui", "数据表格与筛选")}>
          <div class="rounded-box border border-border bg-surface">
            <.filter_bar
              id="demo-filters"
              path={@base}
              filters={@filters}
              dimensions={filter_dimensions()}
            />
            <.data_table
              id="demo-rows"
              rows={@streams.rows}
              label={dgettext("ui", "示例任务")}
              row_version={& &1.version}
              has_more={@loaded < 15}
              load_more="load_more"
            >
              <:col :let={row} label="ID" class="w-24">
                <.task_id_link ident={row.ident} workspace="acme" status={row.status} />
              </:col>
              <:col :let={row} label={dgettext("ui", "标题")}>{row.title}</:col>
              <:col :let={row} label={dgettext("ui", "状态")} secondary class="w-28">
                <.status_badge status={row.status} />
              </:col>
            </.data_table>
          </div>
          <div class="flex gap-2">
            <.button id="bump-row" size="sm" phx-click="bump_row">{dgettext("ui", "更新第一行")}</.button>
            <.button size="sm" phx-click="flash_info">{dgettext("ui", "成功提示")}</.button>
            <.button size="sm" phx-click="flash_error">{dgettext("ui", "错误提示")}</.button>
          </div>
        </.section>

        <.section id="icons" title={dgettext("ui", "图标")}>
          <div class="flex flex-wrap gap-3 text-fg-muted">
            <span
              :for={name <- icons()}
              class="inline-flex items-center gap-1 text-caption"
              title={name}
            >
              <.icon name={name} />{String.replace_prefix(name, "lucide-", "")}
            </span>
          </div>
        </.section>

        <.section id="tokens" title="Token">
          <div class="grid grid-cols-2 gap-2 sm:grid-cols-4 lg:grid-cols-6">
            <div :for={{name, class} <- color_swatches()} class="flex items-center gap-2 text-caption">
              <span class={["size-6 rounded-badge border border-border", class]} />{name}
            </div>
          </div>
          <div class="flex flex-col gap-1">
            <p :for={{name, class} <- type_samples()} class={class}>{name} · 任务管理 Helmsman</p>
          </div>
        </.section>

        <.section id="contrast" title={dgettext("ui", "对比度")}>
          <.contrast_table theme="helmsman-light" class="dark:hidden" />
          <.contrast_table theme="helmsman-dark" class="hidden dark:block" />
        </.section>
      </div>

      <.side_panel
        id="demo-panel"
        show={@params["panel"] == "new"}
        title={dgettext("ui", "新建任务")}
        dirty={@panel_dirty}
        patch_on_close={@close_href}
      >
        <:error :if={@panel_error}>{@panel_error}</:error>
        <.form
          for={@panel_form}
          id="demo-panel-form"
          phx-change="validate_panel"
          phx-submit="save_panel"
          class="flex flex-col gap-3"
        >
          <.input field={@panel_form[:title]} label={dgettext("ui", "标题")} />
          <.input field={@panel_form[:note]} type="textarea" label={dgettext("ui", "说明")} />
        </.form>
        <:footer :let={cancel}>
          <.button
            id="demo-panel-discard"
            variant="ghost"
            phx-click={
              open_overlay("demo-discard", stack_on: "demo-panel", focus: "#demo-discard-cancel")
            }
          >
            {dgettext("ui", "放弃…")}
          </.button>
          <.button phx-click={cancel} class="ml-auto">{dgettext("ui", "取消")}</.button>
          <.button variant="primary" type="submit" form="demo-panel-form">{dgettext("ui", "创建")}</.button>
        </:footer>
      </.side_panel>

      <.confirm_dialog
        id="demo-discard"
        title={dgettext("ui", "放弃填写？")}
        danger
        stack_on="demo-panel"
        confirm_label={dgettext("ui", "放弃")}
        on_confirm={JS.patch(@close_href)}
      >
        {dgettext("ui", "已填写的内容不会保存。")}
      </.confirm_dialog>

      <.modal
        id="demo-modal"
        show={@params["modal"] == "log"}
        title={dgettext("ui", "执行记录")}
        size={:xl}
        patch_on_close={@close_href}
      >
        <p :for={i <- 1..40} class="font-mono text-label text-fg-muted">[{i}] step {i} ok</p>
      </.modal>

      <.confirm_dialog
        id="demo-confirm"
        title={dgettext("ui", "吊销 Token？")}
        danger
        confirm_label={dgettext("ui", "吊销")}
        on_confirm="confirm"
        confirm_value={%{start: "revoked"}}
      >
        {dgettext("ui", "吊销后使用该 Token 的客户端将立即失效。")}
      </.confirm_dialog>

      <.confirm_dialog
        id="demo-start"
        title={dgettext("ui", "认领任务")}
        confirm_label={dgettext("ui", "开始")}
        on_confirm="confirm"
        confirm_value={%{start: "true"}}
      >
        {dgettext("ui", "认领后是否立即开始？")}
        <:secondary_action label={dgettext("ui", "暂不开始")} event="confirm" value={%{start: "false"}} />
      </.confirm_dialog>
    </Layouts.app>
    """
  end

  attr :id, :string, required: true
  attr :title, :string, required: true
  slot :inner_block, required: true

  defp section(assigns) do
    ~H"""
    <section
      id={"section-#{@id}"}
      aria-labelledby={"section-#{@id}-title"}
      class="flex flex-col gap-3"
    >
      <h2 id={"section-#{@id}-title"} class="text-title font-semibold text-fg">{@title}</h2>
      {render_slot(@inner_block)}
    </section>
    """
  end

  attr :theme, :string, required: true
  attr :class, :any, default: nil

  defp contrast_table(assigns) do
    assigns = assign(assigns, :checks, ThemeTokens.checks(assigns.theme))

    ~H"""
    <div class={@class} id={"contrast-#{@theme}"}>
      <p class="mb-2 text-label text-fg-muted">{@theme}</p>
      <div class="grid grid-cols-1 gap-x-6 sm:grid-cols-2 lg:grid-cols-3">
        <div :for={check <- @checks} class="flex h-7 items-center gap-2 text-label">
          <span class="w-24 truncate text-fg-muted">{check.group}</span>
          <span class="flex-1 truncate">{check.fg} / {check.bg}</span>
          <.badge tone={if(check.pass?, do: :success, else: :danger)}>
            {:erlang.float_to_binary(check.ratio, decimals: 2)} ≥ {check.threshold}
          </.badge>
        </div>
      </div>
    </div>
    """
  end

  defp demo_menu_items do
    [
      %{
        label: dgettext("ui", "重命名"),
        icon: "lucide-pencil",
        shortcut: "R",
        on_select: "menu_select",
        value: %{item: "rename"}
      },
      %{
        label: dgettext("ui", "复制链接"),
        icon: "lucide-link",
        description: dgettext("ui", "复制到剪贴板"),
        on_select: "menu_select",
        value: %{item: "copy"}
      },
      %{type: :divider},
      %{
        label: dgettext("ui", "高优先级"),
        group: dgettext("ui", "优先级"),
        checked: true,
        on_select: "menu_select",
        value: %{item: "high"}
      },
      %{
        label: dgettext("ui", "低优先级"),
        group: dgettext("ui", "优先级"),
        checked: false,
        on_select: "menu_select",
        value: %{item: "low"}
      },
      %{type: :divider},
      %{
        label: dgettext("ui", "移动到项目"),
        icon: "lucide-folder-input",
        disabled_reason: dgettext("ui", "只有管理员可以移动")
      },
      %{
        label: dgettext("ui", "删除"),
        icon: "lucide-trash",
        danger: true,
        on_select: "menu_select",
        value: %{item: "delete"}
      }
    ]
  end

  defp long_menu_items do
    for name <- ~w(alice bob carol dave erin frank grace heidi ivan judy mallory oscar) do
      %{label: name, on_select: "menu_select", value: %{item: name}}
    end
  end

  defp filter_dimensions do
    [
      %{
        key: :status,
        label: dgettext("ui", "状态"),
        options: Enum.map(Status.task_statuses(), &{&1, Status.task_status(&1).label})
      },
      %{
        key: :label,
        label: dgettext("ui", "标签"),
        options: [{"api", "api"}, {"ui", "ui"}, {"infra", "infra"}]
      }
    ]
  end

  defp spark_points(now) do
    for i <- 13..0//-1 do
      {Date.add(DateTime.to_date(now), -i), rem(i * 7, 5)}
    end
  end

  defp icons do
    statuses =
      Enum.map(Status.task_statuses(), &Status.task_status(&1).icon) ++
        Enum.map(Status.run_statuses(), &Status.run_status(&1).icon)

    Enum.uniq(
      statuses ++
        ~w(lucide-bot lucide-users lucide-settings lucide-search lucide-square-pen lucide-plus
           lucide-x lucide-check lucide-copy lucide-menu lucide-panel-left lucide-panel-left-open
           lucide-chevrons-up-down lucide-chevron-right lucide-chevron-down lucide-circle-alert
           lucide-circle-check lucide-triangle-alert lucide-user-cog lucide-log-out lucide-monitor
           lucide-sun lucide-moon lucide-link lucide-pencil lucide-trash lucide-folder lucide-folder-input
           lucide-layout-grid lucide-list-filter lucide-funnel-x lucide-search-x lucide-inbox
           lucide-arrow-right lucide-corner-down-left lucide-corner-down-right lucide-git-pull-request
           lucide-git-merge lucide-terminal lucide-cpu lucide-server lucide-ship-wheel lucide-refresh-cw
           lucide-play lucide-ellipsis lucide-loader-circle)
    )
  end

  defp color_swatches do
    [
      {"shell", "bg-shell"},
      {"canvas", "bg-canvas"},
      {"surface", "bg-surface"},
      {"raised", "bg-raised"},
      {"hover", "bg-hover"},
      {"selected", "bg-selected"},
      {"border", "bg-border"},
      {"border-strong", "bg-border-strong"},
      {"fg", "bg-fg"},
      {"fg-muted", "bg-fg-muted"},
      {"fg-subtle", "bg-fg-subtle"},
      {"brand", "bg-brand"},
      {"success", "bg-success"},
      {"warning", "bg-warning"},
      {"danger", "bg-danger"},
      {"info", "bg-info"},
      {"review", "bg-review"},
      {"brand-fg", "bg-brand-fg"},
      {"success-fg", "bg-success-fg"},
      {"warning-fg", "bg-warning-fg"},
      {"danger-fg", "bg-danger-fg"},
      {"info-fg", "bg-info-fg"},
      {"review-fg", "bg-review-fg"}
    ]
  end

  defp type_samples do
    [
      {"display 24/32", "text-display"},
      {"heading 20/28", "text-heading"},
      {"title 16/24", "text-title"},
      {"body 14/20", "text-body"},
      {"label 13/18", "text-label"},
      {"caption 12/16", "text-caption"},
      {"micro 11/14", "text-micro"}
    ]
  end
end
