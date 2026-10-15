defmodule HelmsmanWeb.LocalRepoRegistrationComponents do
  @moduledoc """
  The runtimes page's web registration of local repositories
  (add-local-repo-web-registration D11): the copy of the result codes, the 登记本地仓库
  panel body, the removal dialog and the 网页操作记录 list.

  `register` is the panel state kept by `HelmsmanWeb.SettingsLive.Runtimes`; machines,
  candidates and changes are the maps of `HelmsmanWeb.LocalRepoRegistration`.
  """
  use HelmsmanWeb, :html

  @doc "The text of a result code (D11 文案表); `machine` fills 「<机器>」."
  def code_text(code, machine)
  def code_text(:forbidden, _m), do: dgettext("ui", "只有这台机器的主人能在网页上登记或移除")
  def code_text(:not_found, _m), do: dgettext("ui", "找不到这台机器，或它已不服务本工作区")

  def code_text(:daemon_outdated, m),
    do:
      dgettext(
        "ui",
        "%{machine} 的守护进程版本过旧，升级后才能在网页上登记；也可以在机器上运行 helmsman repos add",
        machine: m
      )

  def code_text(code, m) when code in [:registration_disabled, :disabled],
    do:
      dgettext(
        "ui",
        "%{machine} 没有允许网页登记的目录。在机器上运行 helmsman repos roots add <目录> 后再试，或直接用 helmsman repos add",
        machine: m
      )

  def code_text(:daemon_offline, m), do: dgettext("ui", "%{machine} 离线", machine: m)
  def code_text(:busy, m), do: dgettext("ui", "%{machine} 正在处理另一个请求，稍后再试", machine: m)
  def code_text(:root_not_allowed, _m), do: dgettext("ui", "这个目录已不在允许网页登记的范围内，请重新读取")
  def code_text(:invalid_path, _m), do: dgettext("ui", "路径无效，请重新读取")
  def code_text(:missing, _m), do: dgettext("ui", "机器上已找不到这个目录，请重新读取")

  def code_text(:outside_root, _m),
    do:
      dgettext(
        "ui",
        "这个仓库经过符号链接，或它的 git 数据在允许的目录之外，不能从网页登记；可以在机器上用 helmsman repos add"
      )

  def code_text(:not_a_repository, _m), do: dgettext("ui", "不是可登记的 git 仓库")
  def code_text(:inside_daemon_home, _m), do: dgettext("ui", "仓库在守护进程的主目录里，不能登记")

  def code_text(:invalid_name, _m),
    do: dgettext("ui", "名字只能用小写字母、数字、- 和 _，以字母或数字开头，最多 64 个字符")

  def code_text(:name_taken, _m), do: dgettext("ui", "这台机器上已有同名的本地仓库")
  def code_text(:already_registered, _m), do: dgettext("ui", "这个仓库已经登记过")
  def code_text(:invalid_workspaces, _m), do: dgettext("ui", "所选工作区不在这台机器的服务范围内")
  def code_text(:not_configured, _m), do: dgettext("ui", "机器上已没有这个登记")

  def code_text(:config_error, _m),
    do: dgettext("ui", "机器上的 config.toml 无法安全地自动修改，请在机器上手动编辑")

  def code_text(:timeout, m),
    do:
      dgettext(
        "ui",
        "%{machine} 没有在 20 秒内回复。结果以机器上的配置为准，稍后看列表或下方的操作记录",
        machine: m
      )

  def code_text(:browse_timeout, m),
    do: dgettext("ui", "%{machine} 没有在 15 秒内送回仓库列表", machine: m)

  def code_text(_code, _m), do: dgettext("ui", "操作失败，请重试")

  @doc "The codes whose daemon text follows the copy as 「机器报告：<message>」."
  def reports_message?(code), do: code in [:not_a_repository, :already_registered, :config_error]

  @doc """
  A result code's copy, the daemon's English message (`lang="en"`) where the table has
  one, and for a machine without allowed roots the two copyable commands.
  """
  attr :id, :string, required: true
  attr :code, :atom, required: true
  attr :machine, :string, required: true
  attr :message, :string, default: nil
  attr :slug, :string, required: true
  attr :class, :any, default: nil

  def code_message(assigns) do
    ~H"""
    <span id={@id} class={["flex min-w-0 flex-col gap-1", @class]} data-code={@code}>
      <span>
        {code_text(@code, @machine)}<span :if={@message && reports_message?(@code)}>{dgettext(
          "ui",
          "。机器报告："
        )}<span lang="en">{@message}</span></span>
      </span>
      <span :if={@code in [:registration_disabled, :disabled]} class="flex flex-col gap-1">
        <.copy_command id={"#{@id}-roots-command"} text={roots_add_command()} />
        <.copy_command id={"#{@id}-add-command"} text={repos_add_command(@slug)} />
      </span>
    </span>
    """
  end

  @doc "`helmsman repos roots add <目录>`."
  def roots_add_command, do: "helmsman repos roots add <#{dgettext("ui", "目录")}>"

  @doc "`helmsman repos add <路径> --name <名字> --workspace <slug>`."
  def repos_add_command(slug),
    do:
      "helmsman repos add <#{dgettext("ui", "路径")}> --name <#{dgettext("ui", "名字")}> --workspace #{slug}"

  @doc "A candidate's path label: `.` is the root itself."
  def path_label("."), do: dgettext("ui", "（根目录本身）")
  def path_label(path), do: path

  ## Register panel

  @doc """
  The body of the 登记本地仓库 panel: 1 机器, 2 仓库, 3 登记 (the form
  `#local-repository-register-form`, submitted from the panel footer).
  """
  attr :register, :map, required: true
  attr :machines, :list, required: true
  attr :slug, :string, required: true

  def register_body(assigns) do
    machine = Enum.find(assigns.machines, &(&1.daemon_id == assigns.register.daemon_id))
    assigns = assign(assigns, machine: machine, machine_name: machine && machine.name)

    ~H"""
    <div class="flex flex-col gap-6">
      <section aria-labelledby="register-step-machine">
        <h3 id="register-step-machine" class="mb-2 text-label font-medium text-fg">
          {dgettext("ui", "1. 选择机器")}
        </h3>
        <form id="register-machines" phx-change="select_machine" class="flex flex-col gap-1">
          <div
            :for={m <- @machines}
            id={"register-machine-#{m.daemon_id}-row"}
            data-eligibility={m.eligibility}
            class={[
              "flex flex-col gap-1 rounded-field border px-3 py-2",
              @register.daemon_id == m.daemon_id && "border-brand bg-selected",
              @register.daemon_id != m.daemon_id && "border-border"
            ]}
          >
            <label class={[
              "flex items-center gap-2 text-body",
              m.eligibility == :ok && "cursor-pointer text-fg",
              m.eligibility != :ok && "text-fg-subtle"
            ]}>
              <input
                type="radio"
                id={"register-machine-#{m.daemon_id}"}
                name="daemon_id"
                value={m.daemon_id}
                checked={@register.daemon_id == m.daemon_id}
                disabled={m.eligibility != :ok}
                class="size-4 accent-brand"
              />
              <span class="font-medium">{m.name}</span>
            </label>
            <.code_message
              :if={m.eligibility != :ok}
              id={"register-machine-#{m.daemon_id}-reason"}
              code={m.eligibility}
              machine={m.name}
              slug={@slug}
              class="pl-6 text-caption text-fg-muted"
            />
          </div>
        </form>
      </section>

      <section :if={@machine} id="register-repositories" aria-labelledby="register-step-repository">
        <h3 id="register-step-repository" class="mb-2 text-label font-medium text-fg">
          {dgettext("ui", "2. 选择仓库")}
        </h3>
        <p
          :if={match?({:waiting, _}, @register.browse)}
          id="register-browse-status"
          role="status"
          class="flex items-center gap-2 text-body text-fg-muted"
        >
          <.icon name="lucide-loader-circle" class="size-4 motion-safe:animate-spin" />
          {dgettext("ui", "正在读取 %{machine} 上的仓库…", machine: @machine_name)}
        </p>
        <div
          :if={browse_failed?(@register.browse)}
          id="register-browse-error"
          role="alert"
          class="flex flex-col items-start gap-2 rounded-field border border-danger tint-danger px-3 py-2 text-body text-danger-fg"
        >
          <.code_message
            id="register-browse-error-text"
            code={browse_code(@register.browse)}
            machine={@machine_name}
            message={browse_message(@register.browse)}
            slug={@slug}
          />
          <.button id="register-reread" size="sm" phx-click="reread" icon="lucide-refresh-cw">
            {dgettext("ui", "重新读取")}
          </.button>
        </div>
        <.candidates :if={@register.browse == :ready} register={@register} />
      </section>

      <section :if={@register.selected} id="register-details" aria-labelledby="register-step-details">
        <h3 id="register-step-details" class="mb-2 text-label font-medium text-fg">
          {dgettext("ui", "3. 填写登记信息")}
        </h3>
        <.register_form register={@register} machine={@machine} />
      </section>
    </div>
    """
  end

  defp browse_failed?({:failed, _code, _message}), do: true
  defp browse_failed?(:timeout), do: true
  defp browse_failed?(_), do: false

  defp browse_code({:failed, code, _}), do: code
  defp browse_code(:timeout), do: :browse_timeout

  defp browse_message({:failed, _, message}), do: message
  defp browse_message(_), do: nil

  attr :register, :map, required: true

  defp candidates(assigns) do
    filter = String.downcase(String.trim(assigns.register.filter))

    visible =
      Enum.filter(assigns.register.candidates, fn c ->
        filter == "" or String.contains?(String.downcase(c.path), filter)
      end)

    groups =
      for root <- assigns.register.roots,
          items = Enum.filter(visible, &(&1.root == root)),
          items != [],
          do: {root, items}

    assigns = assign(assigns, groups: groups, none?: assigns.register.candidates == [])

    ~H"""
    <div class="flex flex-col gap-3">
      <p
        :if={@register.truncated}
        id="register-truncated"
        class="rounded-field border border-warning tint-warning px-3 py-2 text-caption text-warning-fg"
      >
        {dgettext("ui", "目录太多，只列出了一部分；可以缩小允许的目录，或在机器上用 helmsman repos add")}
      </p>
      <div
        :if={@none?}
        id="register-no-candidates"
        class="flex flex-col gap-1 text-body text-fg-muted"
      >
        <p>{dgettext("ui", "允许的目录下没有找到 git 仓库")}</p>
        <ul class="flex flex-col gap-0.5">
          <li :for={root <- @register.roots} class="font-mono text-label text-fg">{root}</li>
        </ul>
        <span>
          <.button id="register-reread" size="sm" phx-click="reread" icon="lucide-refresh-cw">
            {dgettext("ui", "重新读取")}
          </.button>
        </span>
      </div>
      <form
        :if={!@none?}
        id="register-candidate-filter-form"
        phx-change="filter_candidates"
        phx-submit="filter_candidates"
      >
        <.input
          id="register-candidate-filter"
          name="filter"
          type="search"
          value={@register.filter}
          placeholder={dgettext("ui", "按路径筛选")}
          aria-label={dgettext("ui", "按路径筛选")}
          autocomplete="off"
          phx-debounce="150"
        />
      </form>
      <div :if={!@none?} id="register-candidates" class="flex flex-col gap-3">
        <p :if={@groups == []} id="register-candidates-none" class="text-body text-fg-muted">
          {dgettext("ui", "没有匹配的仓库")}
        </p>
        <div
          :for={{{root, items}, g} <- Enum.with_index(@groups)}
          role="group"
          aria-labelledby={"register-root-#{g}"}
        >
          <p
            id={"register-root-#{g}"}
            class="mb-1 truncate font-mono text-caption text-fg-muted"
            title={root}
          >
            {root}
          </p>
          <ul class="flex flex-col gap-0.5">
            <li :for={c <- items}>
              <button
                id={"register-candidate-#{c.index}"}
                type="button"
                phx-click="select_candidate"
                phx-value-index={c.index}
                disabled={c.registered_as != nil}
                aria-pressed={to_string(@register.selected == c.index)}
                data-registered-as={c.registered_as}
                class={[
                  "flex w-full items-center justify-between gap-2 rounded-field px-2 py-1.5 text-left text-body",
                  @register.selected == c.index && "bg-selected text-fg",
                  @register.selected != c.index && c.registered_as == nil && "text-fg hover:bg-hover",
                  c.registered_as != nil && "cursor-not-allowed text-fg-subtle"
                ]}
              >
                <span class="min-w-0 truncate font-mono text-label">{path_label(c.path)}</span>
                <span :if={c.registered_as} class="flex-none text-caption">
                  {dgettext("ui", "已登记为 %{name}", name: c.registered_as)}
                </span>
              </button>
            </li>
          </ul>
        </div>
      </div>
    </div>
    """
  end

  attr :register, :map, required: true
  attr :machine, :map, required: true

  defp register_form(assigns) do
    candidate = Enum.at(assigns.register.candidates, assigns.register.selected)
    assigns = assign(assigns, :candidate, candidate)

    ~H"""
    <.form
      for={%{}}
      as={:register}
      id="local-repository-register-form"
      phx-change="validate_register"
      phx-submit="register"
      class="flex flex-col gap-4"
    >
      <p id="register-location" class="flex min-w-0 flex-wrap gap-1 text-caption text-fg-muted">
        <span>{dgettext("ui", "位置")}</span>
        <code class="min-w-0 break-all font-mono text-fg">
          {@candidate.root} / {path_label(@candidate.path)}
        </code>
      </p>
      <fieldset
        id="register-fields"
        disabled={@register.submit != nil}
        class="flex min-w-0 flex-col gap-4 disabled:opacity-70"
      >
        <.input
          id="register-name"
          name="register[name]"
          label={dgettext("ui", "名字")}
          value={@register.name}
          maxlength="64"
          autocomplete="off"
          errors={List.wrap(@register.errors[:name])}
        />
        <fieldset
          id="register-workspaces"
          class="flex flex-col gap-1"
          aria-describedby={@register.errors[:workspaces] && "register-workspaces-error"}
        >
          <legend class="mb-1 text-label font-medium text-fg">{dgettext("ui", "开放给")}</legend>
          <input type="hidden" name="register[workspace_ids][]" value="" />
          <label
            :for={w <- @machine.workspaces}
            id={"register-workspace-#{w.id}"}
            data-invalid={to_string(w.id in @register.invalid_workspaces)}
            class={[
              "flex items-center gap-2 rounded-field px-2 py-1.5",
              w.id in @register.invalid_workspaces && "border border-danger tint-danger"
            ]}
          >
            <input
              type="checkbox"
              name="register[workspace_ids][]"
              value={w.id}
              checked={w.id in @register.workspace_ids}
              class="size-4 accent-brand"
            />
            <span class="text-body text-fg">{w.name}</span>
          </label>
          <p
            :if={@register.errors[:workspaces]}
            id="register-workspaces-error"
            class="flex items-center gap-1 text-caption text-danger-fg"
          >
            <.icon name="lucide-circle-alert" class="size-3.5" />{@register.errors[:workspaces]}
          </p>
        </fieldset>
      </fieldset>
    </.form>
    """
  end

  ## Removal dialog

  @doc "The confirmation dialog of 移除 (`remove` the page's dialog state, or nil)."
  attr :remove, :map, default: nil
  attr :slug, :string, required: true

  def remove_dialog(assigns) do
    ~H"""
    <.overlay
      id="local-repository-remove-dialog"
      show={@remove != nil}
      role="alertdialog"
      on_cancel={JS.push("dismiss_remove")}
      focus="#local-repository-remove-dialog-cancel"
      describedby="local-repository-remove-dialog-description"
      position_class="items-center justify-center p-4"
      container_class="w-full max-w-[480px] rounded-box border border-border"
    >
      <div :if={@remove} class="px-5 pt-5">
        <h2 id="local-repository-remove-dialog-title" class="text-title font-semibold text-fg">
          {dgettext("ui", "从 %{machine} 的配置中移除 %{name}？",
            machine: @remove.machine,
            name: @remove.name
          )}
        </h2>
        <div
          id="local-repository-remove-dialog-description"
          class="mt-2 flex flex-col gap-2 text-body text-fg-muted"
        >
          <p>
            {dgettext("ui", "与在机器上执行以下命令相同：")}
            <code class="font-mono text-fg">helmsman repos remove {@remove.name}</code>
          </p>
          <p id="local-repository-remove-workspaces">
            {dgettext("ui", "它在这些工作区都会变为不可用：%{workspaces}",
              workspaces: Enum.map_join(@remove.workspaces, "、", & &1.name)
            )}
          </p>
          <p :if={@remove.projects != []} id="local-repository-remove-projects">
            {dgettext("ui", "绑定它的项目 %{keys} 保留绑定，但无法执行运行", keys: Enum.join(@remove.projects, "、"))}
          </p>
          <p>{dgettext("ui", "机器上的仓库文件和其中的 hm/… 分支都不会改变")}</p>
        </div>
        <p
          :if={@remove.waiting}
          id="local-repository-remove-status"
          role="status"
          class="mt-3 flex items-center gap-2 text-body text-fg-muted"
        >
          <.icon name="lucide-loader-circle" class="size-4 motion-safe:animate-spin" />
          {dgettext("ui", "正在等待 %{machine} 确认…", machine: @remove.machine)}
        </p>
        <div
          :if={@remove.error}
          id="local-repository-remove-error"
          role="alert"
          class="mt-3 rounded-field border border-danger tint-danger px-3 py-2 text-body text-danger-fg"
        >
          <.code_message
            id="local-repository-remove-error-text"
            code={elem(@remove.error, 0)}
            machine={@remove.machine}
            message={elem(@remove.error, 1)}
            slug={@slug}
          />
        </div>
      </div>
      <div :if={@remove} class="flex items-center justify-end gap-2 px-5 py-4">
        <.button id="local-repository-remove-dialog-cancel" phx-click={JS.push("dismiss_remove")}>
          {dgettext("ui", "取消")}
        </.button>
        <.button
          id="local-repository-remove-confirm"
          variant="danger"
          phx-click="remove_local"
          disabled={@remove.waiting != nil}
        >
          {dgettext("ui", "移除")}
        </.button>
      </div>
    </.overlay>
    """
  end

  ## Changes

  @doc "The 网页操作记录 list (hidden without changes)."
  attr :changes, :list, required: true
  attr :slug, :string, required: true

  def changes(assigns) do
    ~H"""
    <section
      :if={@changes != []}
      id="local-repository-changes"
      aria-labelledby="local-repository-changes-title"
      class="mt-6"
    >
      <h3 id="local-repository-changes-title" class="mb-2 text-label font-medium text-fg">
        {dgettext("ui", "网页操作记录")}
      </h3>
      <div class="overflow-x-auto rounded-box border border-border bg-surface">
        <table class="w-full text-body">
          <thead class="text-left text-caption text-fg-muted">
            <tr class="border-b border-border">
              <th class="px-3 py-2 font-medium">{dgettext("ui", "时间")}</th>
              <th class="px-3 py-2 font-medium">{dgettext("ui", "操作人")}</th>
              <th class="hidden px-3 py-2 font-medium md:table-cell">{dgettext("ui", "机器")}</th>
              <th class="px-3 py-2 font-medium">{dgettext("ui", "动作")}</th>
              <th class="px-3 py-2 font-medium">{dgettext("ui", "名字")}</th>
              <th class="hidden px-3 py-2 font-medium md:table-cell">{dgettext("ui", "位置")}</th>
              <th class="px-3 py-2 font-medium">{dgettext("ui", "结果")}</th>
            </tr>
          </thead>
          <tbody class="divide-y divide-border">
            <tr
              :for={c <- @changes}
              id={"local-repository-change-#{c.id}"}
              data-state={c.state}
              class="align-top"
            >
              <td class="whitespace-nowrap px-3 py-2 text-fg-muted">
                <.relative_time id={"local-repository-change-#{c.id}-at"} at={c.inserted_at} />
              </td>
              <td class="px-3 py-2 text-fg" data-operator>{c.operator.name}</td>
              <td class="hidden px-3 py-2 text-fg md:table-cell" data-machine>{c.daemon_name}</td>
              <td class="whitespace-nowrap px-3 py-2 text-fg" data-action={c.action}>
                {action_label(c.action)}
              </td>
              <td class="px-3 py-2 font-mono text-fg" data-name>{c.name}</td>
              <td class="hidden max-w-64 px-3 py-2 md:table-cell">
                <code
                  :if={c.root && c.path}
                  class="break-all font-mono text-label text-fg-muted"
                  data-location
                >
                  {c.root} / {c.path}
                </code>
              </td>
              <td class="px-3 py-2" data-result>
                <.change_result id={"local-repository-change-#{c.id}-result"} change={c} slug={@slug} />
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </section>
    """
  end

  defp action_label(:register), do: dgettext("ui", "登记")
  defp action_label(:remove), do: dgettext("ui", "移除")
  defp action_label(_), do: ""

  attr :id, :string, required: true
  attr :change, :map, required: true
  attr :slug, :string, required: true

  defp change_result(%{change: %{state: :failed}} = assigns) do
    ~H"""
    <span class="flex flex-col gap-0.5 text-caption">
      <.badge tone={:danger} class="w-fit">{dgettext("ui", "失败")}</.badge>
      <span :if={@change.error} class="text-fg-muted">
        <.code_message
          id={@id}
          code={@change.error}
          machine={@change.daemon_name}
          message={@change.message}
          slug={@slug}
        />
      </span>
    </span>
    """
  end

  defp change_result(assigns) do
    {tone, label} = result_spec(assigns.change.state)
    assigns = assign(assigns, tone: tone, label: label)

    ~H"""
    <.badge tone={@tone}>{@label}</.badge>
    """
  end

  defp result_spec(:succeeded), do: {:success, dgettext("ui", "成功")}
  defp result_spec(:pending), do: {:info, dgettext("ui", "等待中")}
  defp result_spec(:no_reply), do: {:muted, dgettext("ui", "没有收到回复")}
  defp result_spec(_), do: {:muted, "—"}
end
