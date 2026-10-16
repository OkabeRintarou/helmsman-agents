defmodule HelmsmanWeb.AgentDesignEdit do
  @moduledoc """
  The edit conversation parts of `HelmsmanWeb.AgentDesignLive`'s `:edit` action
  (`/w/:slug/agent-design/edit?target=<名字>`; spec web-agent-design 「修改对话的入口与
  页面」「修改草稿的对比」「确认修改的界面」; add-edit-design-conversations D14): the
  start area, the empty states, the note about another target, the draft column
  comparing the draft with the baseline, and the confirmation's content.

  The view (`AgentDesigns.get/2`) brings `target`, `baseline`, `changes` (long texts
  with their line hunks, a squad's members as added / removed / notes), `conflicts` and
  `readonly`; someone other than the agent's owner gets the provider account as
  `%{"name", "host"}`, never its ID.
  """
  use HelmsmanWeb, :html

  import HelmsmanWeb.AgentComponents, only: [provider_label: 1]
  import HelmsmanWeb.AgentDesignComponents
  import HelmsmanWeb.Components.TextDiff
  import HelmsmanWeb.DesignConversationComponents, only: [message_box: 1, max_bytes: 0]

  alias HelmsmanWeb.{AgentDesignSquad, Url}

  @long ~w(description instructions)

  ## State

  @doc "Whether `design` is an edit conversation."
  def edit?(%{kind: kind}), do: kind in [:agent_edit, :squad_edit]
  def edit?(_design), do: false

  @doc "The number of changed fields of an edit conversation's draft."
  def change_count(%{changes: changes}), do: length(changes)

  @doc "The draft's new agents (a `squad_edit` conversation)."
  def new_agents(%{kind: :squad_edit, draft: %{"agents" => agents}}) when is_list(agents),
    do: agents

  def new_agents(_design), do: []

  @doc "The draft entry of an `agent_edit` conversation's target."
  def target_entry(%{kind: :agent_edit, draft: %{"agents" => [entry | _]}}), do: entry
  def target_entry(_design), do: nil

  @doc """
  The options of the target's draft panel (`AgentForm.draft_edit/5`): the name is fixed,
  fields revert to the baseline, and someone who is not the owner only edits the
  description and the limits. A squad's new agents are plain draft agents.
  """
  def form_opts(%{kind: :agent_edit} = design, %{"name" => name}) do
    if same?(name, target_entry(design)["name"]),
      do: [
        lock_name: true,
        baseline: design.baseline["agent"],
        configure?: design.readonly == []
      ],
      else: []
  end

  def form_opts(_design, _entry), do: []

  @doc "Why 「应用修改」 is unavailable now, or nil."
  def confirm_reason(design, open?) do
    cond do
      not open? ->
        dgettext("ui", "对话已结束")

      design.current_run != nil ->
        dgettext("ui", "等 %{helper} 回复完再确认", helper: design.helper.name)

      change_count(design) == 0 and new_agents(design) == [] ->
        dgettext("ui", "草稿与当前配置相同，没有修改")

      true ->
        nil
    end
  end

  @doc "「应用 N 项修改」 / 「应用 N 项修改并创建 M 个 Agent」."
  def confirm_label(design) do
    n = change_count(design)

    case length(new_agents(design)) do
      0 -> dngettext("ui", "应用 %{count} 项修改", "应用 %{count} 项修改", n)
      m -> dgettext("ui", "应用 %{n} 项修改并创建 %{m} 个 Agent", n: n, m: m)
    end
  end

  @doc "The page title: 「用对话修改 <名字>」."
  def heading(name), do: dgettext("ui", "用对话修改 %{name}", name: name)

  @doc "The detail page of the target `%{name, kind}`."
  def target_path(slug, %{kind: :squad, name: name}), do: Url.squad_path(slug, name)
  def target_path(slug, %{name: name}), do: Url.agent_path(slug, name)

  @doc "The snapshot the confirmation shows (its draft version)."
  def snapshot(design) do
    %{
      version: design.draft_version,
      edit?: true,
      target: design.target,
      changes: design.changes,
      agents: new_agents(design)
    }
  end

  ## The start area and the empty states

  attr :helpers, :list, required: true
  attr :choice, :string, default: nil
  attr :target, :map, required: true, doc: "`%{name, kind}`"
  attr :message, :string, required: true
  attr :gen, :integer, required: true
  attr :errors, :map, required: true
  attr :scope, :map, required: true

  @doc "Choosing the helper and the first message of an edit conversation."
  def start_area(assigns) do
    selected = Enum.find(assigns.helpers, &(&1.name == assigns.choice))

    assigns =
      assign(assigns,
        selected: selected,
        none?: not Enum.any?(assigns.helpers, &(&1.dispatchability == :ok)),
        bytes: byte_size(assigns.message)
      )

    ~H"""
    <div id="design-start" class="mx-auto flex w-full max-w-[720px] flex-col gap-4 px-4 py-8">
      <div>
        <h2 class="text-title font-semibold text-fg">
          {dgettext("ui", "说说想怎么修改 %{name}", name: @target.name)}
        </h2>
        <p id="design-edit-baseline" class="mt-1 text-body text-fg-muted">
          {dgettext(
            "ui",
            "以 %{name} 当前的配置为起点。AI 只改草稿，你确认后才写入改过的字段；改名、停用、归档请到详情页操作。",
            name: @target.name
          )}
        </p>
      </div>
      <.form
        for={%{}}
        id="design-start-form"
        phx-change="start_change"
        phx-submit="edit_start"
        class="flex flex-col gap-4"
      >
        <.message_box
          id={"design-start-message-#{@gen}"}
          message={@message}
          rows="6"
          placeholder={dgettext("ui", "例如：改用 opus，指令里加上 Storybook")}
          errors={Map.get(@errors, :message, [])}
        />

        <div class="flex flex-col gap-1">
          <label for="design-start-helper" class="text-label font-medium text-fg">
            {dgettext("ui", "起草 Agent")}
          </label>
          <select
            id="design-start-helper"
            name="helper"
            disabled={@none?}
            class="h-8 w-full rounded-field border border-border-strong bg-surface px-2 text-body text-fg disabled:opacity-60"
          >
            <option
              :for={h <- @helpers}
              value={h.name}
              selected={h.name == @choice}
              disabled={h.dispatchability != :ok}
            >
              {helper_option(h, @scope)}
            </option>
          </select>
          <p
            :for={msg <- Map.get(@errors, :helper, [])}
            id="design-start-helper-error"
            class="text-caption text-danger-fg"
          >
            {msg}
          </p>
          <p :if={@none?} id="design-start-no-helper" class="text-caption text-fg-muted">
            {dgettext("ui", "没有你能触发的托管 Agent，无法开始对话")}
          </p>
        </div>

        <div
          :if={@selected}
          id="design-visibility"
          role="note"
          class="rounded-field border border-border bg-surface px-3 py-2 text-caption text-fg-muted"
        >
          {visibility_text(@selected, @scope)}{dgettext(
            "ui",
            "它的回复会出现在 %{helper} 的执行记录里，工作区成员都能看到。不要粘贴密钥或密码。",
            helper: @selected.name
          )}
        </div>

        <div class="flex justify-end">
          <.button
            id="design-start-submit"
            type="submit"
            variant="primary"
            disabled={@none? or @bytes > max_bytes()}
            phx-disable-with={dgettext("ui", "正在开始…")}
          >
            {dgettext("ui", "开始对话")}
          </.button>
        </div>
      </.form>
    </div>
    """
  end

  @doc "A helper as an option: name, CLI, owner and why it cannot run."
  def helper_option(h, scope) do
    base = "#{h.name} · #{provider_label(h.provider)} · #{owner_name(h, scope)}"

    case helper_reason(h) do
      nil -> base
      reason -> "#{base}（#{reason}）"
    end
  end

  @doc "Where the conversation runs."
  def visibility_text(%{owner: %{user_id: id}} = h, %{user: %{id: id}}),
    do: dgettext("ui", "对话会在你的机器上由 %{helper} 处理。", helper: h.name)

  def visibility_text(h, _scope),
    do: dgettext("ui", "对话会在 %{owner} 的机器上由 %{helper} 处理。", owner: h.owner.name, helper: h.name)

  attr :reason, :atom, required: true, doc: ":forbidden | :not_found"
  attr :name, :string, default: nil

  @doc "Why no edit conversation can start here (no start area)."
  def blocked(assigns) do
    ~H"""
    <div id="design-edit-blocked" class="px-4 py-10" data-reason={@reason}>
      <.empty_state
        icon="lucide-lock"
        title={blocked_title(@reason, @name)}
        description={blocked_text(@reason)}
      />
    </div>
    """
  end

  defp blocked_title(:forbidden, name),
    do: dgettext("ui", "你不能用对话修改 %{name}", name: name || "")

  defp blocked_title(_not_found, nil), do: dgettext("ui", "没有指定要修改的 Agent 或小队")
  defp blocked_title(_not_found, name), do: dgettext("ui", "找不到可修改的 %{name}", name: name)

  defp blocked_text(:forbidden),
    do: dgettext("ui", "Agent 只有所属用户与管理员能修改；小队只有能管理它的人能修改。")

  defp blocked_text(_not_found),
    do: dgettext("ui", "它可能不存在、已归档，或是外接 Agent（外接 Agent 不能用对话修改）。")

  attr :current, :string, required: true
  attr :wanted, :string, required: true

  @doc "「你正在修改 <另一个名字>，确认或放弃后才能修改 <名字>」."
  def other_target(assigns) do
    ~H"""
    <p
      id="design-edit-other"
      role="status"
      class="flex flex-none items-center gap-2 border-b border-warning tint-warning px-4 py-2 text-body text-warning-fg"
    >
      <.icon name="lucide-info" class="size-4 shrink-0" />
      {dgettext("ui", "你正在修改 %{current}，确认或放弃后才能修改 %{wanted}",
        current: @current,
        wanted: @wanted
      )}
    </p>
    """
  end

  ## The draft column

  attr :class, :any, default: nil
  attr :design, :map, required: true
  attr :lookup, :map, required: true
  attr :invalid, :map, default: nil
  attr :squad_invalid, :map, default: nil
  attr :target_errors, :map, default: nil
  attr :baseline_notice, :list, default: nil
  attr :humans, :any, required: true
  attr :locked, :string, default: nil
  attr :confirm_reason, :string, default: nil
  attr :highlight, :map, required: true
  attr :appearance, :map, default: %{}
  attr :scope, :map, required: true

  @doc "The draft against the baseline, with 「应用 N 项修改」."
  def draft_column(assigns) do
    design = assigns.design

    assigns =
      assign(assigns,
        n: change_count(design),
        new: new_agents(design),
        name: (design.target && design.target.name) || "",
        pending: edits_text(design.pending_edits),
        changes: Map.new(design.changes, &{&1.field, &1})
      )

    ~H"""
    <section
      id="design-draft"
      class={["flex min-h-0 min-w-0 flex-col bg-canvas", @class]}
      aria-label={dgettext("ui", "草稿")}
      data-kind={@design.kind}
    >
      <header class="flex flex-none items-center gap-2 border-b border-border px-4 py-2">
        <h2 class="text-label font-semibold text-fg">{dgettext("ui", "草稿")}</h2>
        <span id="design-change-count" class="text-caption tabular-nums text-fg-muted">
          {dngettext("ui", "%{count} 项修改", "%{count} 项修改", @n)}
        </span>
      </header>

      <div class="min-h-0 flex-1 overflow-y-auto px-4 py-3">
        <div class="flex flex-col gap-3">
          <p
            :if={@baseline_notice}
            id="design-baseline-changed"
            role="alert"
            class="rounded-field border border-warning tint-warning px-3 py-2 text-body text-warning-fg"
          >
            {dgettext("ui", "%{name} 在对话期间被修改（%{fields}），对比已更新，请检查后重新确认",
              name: @name,
              fields: Enum.map_join(@baseline_notice, "、", &label(@design, &1))
            )}
          </p>
          <p
            :if={@pending}
            id="design-pending"
            role="status"
            class="rounded-field border border-info tint-info px-3 py-2 text-caption text-info-fg"
          >
            {dgettext("ui", "这些修改会在你下一条消息时告诉 AI：%{edits}", edits: @pending)}
          </p>

          <.target_card
            :if={@design.kind == :agent_edit}
            design={@design}
            changes={@changes}
            lookup={@lookup}
            errors={@target_errors}
            locked={@locked}
            scope={@scope}
          />

          <.squad_card
            :if={@design.kind == :squad_edit}
            design={@design}
            changes={@changes}
            humans={@humans}
            errors={@squad_invalid}
            locked={@locked}
          />

          <div :if={@design.kind == :squad_edit} id="design-new-agents" class="flex flex-col gap-2">
            <div class="flex items-center gap-2">
              <h3 class="text-label font-semibold text-fg">
                {dgettext("ui", "新 Agent（%{n}）", n: length(@new))}
              </h3>
              <.button
                id="design-add"
                size="xs"
                variant="ghost"
                icon="lucide-plus"
                class="ml-auto"
                phx-click="add_agent"
                disabled_reason={
                  @locked || if(length(@new) >= 8, do: dgettext("ui", "最多 8 个新 Agent"))
                }
              >
                {dgettext("ui", "添加 Agent")}
              </.button>
            </div>
            <p :if={@new == []} class="text-caption text-fg-muted">
              {dgettext("ui", "需要新成员时，AI 会在这里提出新 Agent，确认时与小队的修改一起创建。")}
            </p>
            <.draft_card
              :for={{a, i} <- Enum.with_index(@new)}
              agent={a}
              index={i}
              lookup={@lookup}
              errors={card_errors(@invalid, a["name"])}
              locked={@locked}
              remove_reason={
                if(AgentDesignSquad.references?(@design.draft, a["name"]),
                  do: AgentDesignSquad.referenced_text(a["name"])
                )
              }
              scope={@scope}
            />
          </div>
        </div>
      </div>

      <footer
        :if={@design.status == :open}
        class="flex flex-none items-center justify-between gap-2 border-t border-border px-4 py-3"
      >
        <.button id="design-discard-open" size="sm" phx-click="ask_discard">
          {dgettext("ui", "放弃")}
        </.button>
        <.button
          id="design-confirm-open"
          size="sm"
          variant="primary"
          phx-click="ask_confirm"
          disabled_reason={@confirm_reason}
        >
          {confirm_label(@design)}
        </.button>
      </footer>
    </section>
    """
  end

  defp card_errors(nil, _name), do: []

  defp card_errors(invalid, name),
    do: for({field, msgs} <- Map.get(invalid, name, %{}), msg <- msgs, do: {field, msg})

  defp label(%{kind: :squad_edit}, field), do: AgentDesignSquad.field_label(field)
  defp label(_design, field), do: field_label(field)

  ## The target agent

  @rows ~w(description provider runtime_id provider_account_id model effort access capabilities mcp_servers
           max_concurrency timeout_minutes idle_timeout_minutes instructions)

  attr :design, :map, required: true
  attr :changes, :map, required: true
  attr :lookup, :map, required: true
  attr :errors, :map, default: nil
  attr :locked, :string, default: nil
  attr :scope, :map, required: true

  defp target_card(assigns) do
    entry = target_entry(assigns.design)
    baseline = assigns.design.baseline["agent"]

    rows =
      for field <- @rows do
        change = assigns.changes[field]

        %{
          field: field,
          change: change,
          now: value_text(field, entry, assigns.lookup),
          before: change && value_text(field, baseline, assigns.lookup),
          conflict?: field in assigns.design.conflicts,
          readonly?: field in assigns.design.readonly,
          errors: Map.get(assigns.errors || %{}, String.to_existing_atom(field), [])
        }
      end

    assigns = assign(assigns, entry: entry, rows: rows)

    ~H"""
    <article
      id="edit-target"
      data-name={@entry["name"]}
      class="flex min-w-0 flex-col gap-2 rounded-box border border-border bg-surface p-3"
    >
      <div class="flex min-w-0 items-center gap-2">
        <span class="min-w-0 truncate font-mono text-body font-semibold text-fg">{@design.target.name}</span>
        <.badge :if={@entry["updated_by"] == "ai"} tone={:info}>{dgettext("ui", "AI 修改")}</.badge>
        <.badge :if={@entry["updated_by"] == "user"} tone={:brand}>{dgettext("ui", "你修改")}</.badge>
        <.icon_button
          id="edit-target-edit"
          icon="lucide-pencil"
          size="sm"
          class="ml-auto"
          label={dgettext("ui", "编辑")}
          phx-click="edit_agent"
          phx-value-name={@entry["name"]}
          disabled_reason={@locked}
        />
      </div>
      <ul class="flex flex-col divide-y divide-border">
        <li
          :for={row <- @rows}
          id={"edit-field-#{row.field}"}
          data-changed={row.change != nil && "true"}
          data-conflict={row.conflict? && "true"}
          data-readonly={row.readonly? && "true"}
          class={[
            "flex min-w-0 flex-col gap-1 py-1.5",
            row.change && "border-l-2 border-l-brand pl-2"
          ]}
        >
          <div class="flex min-w-0 items-center gap-2">
            <span class="w-24 shrink-0 text-caption text-fg-muted">{field_label(row.field)}</span>
            <span
              :if={row.field not in ~w(description instructions) or row.change == nil}
              class="min-w-0 flex-1 truncate text-body text-fg"
            >
              <span
                :if={row.change && row.field not in ~w(description instructions)}
                class="text-fg-muted line-through"
                data-before
              >
                {row.before}
              </span>
              <span
                :if={row.change && row.field not in ~w(description instructions)}
                class="text-fg-muted"
              >→</span>
              <span data-now>{row.now}</span>
            </span>
            <span :if={row.change && row.field in ~w(description instructions)} class="flex-1" />
            <span
              :if={row.readonly?}
              class="flex items-center gap-1 text-caption text-fg-muted"
              data-lock
            >
              <.icon name="lucide-lock" class="size-3" />{dgettext("ui", "只有所属用户能改")}
            </span>
            <.button
              :if={row.change && !row.readonly?}
              id={"edit-revert-#{row.field}"}
              size="xs"
              variant="ghost"
              phx-click="edit_revert"
              phx-value-part="agent"
              phx-value-field={row.field}
              disabled_reason={@locked}
            >
              {dgettext("ui", "恢复")}
            </.button>
          </div>
          <.text_diff
            :if={row.change && row.change[:hunks]}
            id={"edit-diff-#{row.field}"}
            hunks={row.change.hunks}
          />
          <p :if={row.conflict?} class="text-caption text-warning-fg" data-conflict-note>
            {dgettext("ui", "对话期间已被改为 %{current}，草稿保留 %{draft}",
              current: value_text(row.field, @design.baseline["agent"], @lookup),
              draft: row.now
            )}
          </p>
          <p :if={warn_text(row)} class="text-caption text-warning-fg" data-warn={row.field}>
            {warn_text(row)}
          </p>
          <p :for={msg <- row.errors} class="text-caption text-danger-fg" data-error={row.field}>
            {msg}
          </p>
        </li>
      </ul>
    </article>
    """
  end

  # The risky changes stand out (D14): who may trigger, creating tasks, where it runs.
  defp warn_text(%{change: nil}), do: nil

  defp warn_text(%{field: "access", change: %{to: "workspace"}}),
    do: dgettext("ui", "工作区所有成员都能触发它，在所属用户的机器上运行")

  defp warn_text(%{field: "capabilities", change: %{to: to, from: from}}) do
    if "create_tasks" in List.wrap(to) and "create_tasks" not in List.wrap(from),
      do: dgettext("ui", "它将能在工作区里新建任务并指派")
  end

  defp warn_text(%{field: "runtime_id", change: %{to: nil}}),
    do: dgettext("ui", "解绑运行时：排队中的运行会被取消")

  defp warn_text(%{field: "runtime_id"}), do: dgettext("ui", "换运行时：排队中的运行会改到新运行时")

  defp warn_text(%{field: field}) when field in ~w(provider_account_id provider_account),
    do: dgettext("ui", "换供应商账号：之后的运行用新账号的额度")

  defp warn_text(_row), do: nil

  @doc "A draft field's value as shown (no secret: accounts by name)."
  def value_text(_field, nil, _lookup), do: ""

  def value_text("provider", entry, _lookup), do: provider_label(entry["provider"])

  def value_text("runtime_id", entry, lookup) do
    case entry["runtime_id"] do
      nil ->
        dgettext("ui", "不绑定")

      id ->
        case lookup.runtimes[id] do
          %{daemon: %{name: name}} -> name
          _ -> dgettext("ui", "运行时 #%{id}", id: id)
        end
    end
  end

  def value_text("provider_account_id", entry, lookup) do
    case entry do
      %{"provider_account" => %{"name" => name, "host" => host}} ->
        "#{name}（#{host}）"

      %{"provider_account_id" => nil} ->
        dgettext("ui", "CLI 默认登录")

      %{"provider_account_id" => id} when is_integer(id) ->
        case lookup.accounts[id] do
          %{name: name} -> name
          _ -> dgettext("ui", "账号 #%{id}", id: id)
        end

      _ ->
        dgettext("ui", "CLI 默认登录")
    end
  end

  def value_text(field, entry, _lookup) when field in ~w(model effort),
    do: entry[field] || dgettext("ui", "缺省")

  def value_text("access", entry, _lookup) do
    case entry["access"] do
      "workspace" -> dgettext("ui", "工作区所有成员")
      "members" -> dgettext("ui", "指定成员")
      _ -> dgettext("ui", "仅所属用户")
    end
  end

  def value_text("capabilities", entry, _lookup) do
    if "create_tasks" in List.wrap(entry["capabilities"]),
      do: dgettext("ui", "可以建任务"),
      else: dgettext("ui", "只能更新自己的任务")
  end

  def value_text("mcp_servers", entry, lookup) do
    Enum.map_join(List.wrap(entry["mcp_servers"]), ", ", fn name ->
      case Map.get(Map.get(lookup, :mcp_servers, %{}), name) do
        nil -> name
        type -> "#{name}（#{type}）"
      end
    end)
  end

  def value_text("instructions", entry, _lookup),
    do: byte_text(byte_size(entry["instructions"] || ""))

  def value_text(field, entry, _lookup), do: to_string(entry[field] || "")

  ## The squad

  attr :design, :map, required: true
  attr :changes, :map, required: true
  attr :humans, :any, required: true
  attr :errors, :map, default: nil
  attr :locked, :string, default: nil

  defp squad_card(assigns) do
    squad = assigns.design.draft["squad"] || %{}
    base = assigns.design.baseline["squad"] || %{}
    members = assigns.changes["members"]

    assigns =
      assign(assigns,
        squad: squad,
        base: base,
        members: members,
        added: (members && MapSet.new(members.added, &String.downcase/1)) || MapSet.new(),
        noted: (members && MapSet.new(members.notes, &String.downcase/1)) || MapSet.new(),
        removed: (members && members.removed) || []
      )

    ~H"""
    <article
      id="edit-squad"
      class="flex min-w-0 flex-col gap-2 rounded-box border border-border bg-surface p-3"
    >
      <div class="flex min-w-0 items-center gap-2">
        <span class="min-w-0 truncate font-mono text-body font-semibold text-fg">{@design.target.name}</span>
        <.badge tone={:muted}>{dgettext("ui", "小队")}</.badge>
        <.icon_button
          id="edit-squad-edit"
          icon="lucide-pencil"
          size="sm"
          class="ml-auto"
          label={dgettext("ui", "编辑小队")}
          phx-click="edit_squad"
          disabled_reason={@locked}
        />
      </div>
      <ul :if={@errors} role="alert" class="text-caption text-danger-fg">
        <li :for={{field, msg} <- squad_errors(@errors)}>
          {AgentDesignSquad.field_label(field)}：{msg}
        </li>
      </ul>
      <ul class="flex flex-col divide-y divide-border">
        <li
          :for={field <- ~w(description instructions leader)}
          id={"edit-field-#{field}"}
          data-changed={@changes[field] != nil && "true"}
          data-conflict={field in @design.conflicts && "true"}
          class={[
            "flex min-w-0 flex-col gap-1 py-1.5",
            @changes[field] && "border-l-2 border-l-brand pl-2"
          ]}
        >
          <div class="flex min-w-0 items-center gap-2">
            <span class="w-24 shrink-0 text-caption text-fg-muted">{AgentDesignSquad.field_label(
              field
            )}</span>
            <span :if={field == "leader"} class="min-w-0 flex-1 truncate font-mono text-body text-fg">
              <span :if={@changes[field]} class="text-fg-muted line-through" data-before>{@base[field]}</span>
              <span :if={@changes[field]} class="text-fg-muted">→</span>
              <span data-now>{@squad[field]}</span>
            </span>
            <span :if={field != "leader"} class="min-w-0 flex-1 truncate text-body text-fg-muted">
              {byte_text(byte_size(@squad[field] || ""))}
            </span>
            <.button
              :if={@changes[field]}
              id={"edit-revert-#{field}"}
              size="xs"
              variant="ghost"
              phx-click="edit_revert"
              phx-value-part="squad"
              phx-value-field={field}
              disabled_reason={@locked}
            >
              {dgettext("ui", "恢复")}
            </.button>
          </div>
          <.text_diff
            :if={@changes[field] && @changes[field][:hunks]}
            id={"edit-diff-#{field}"}
            hunks={@changes[field].hunks}
          />
          <p :if={field in @design.conflicts} class="text-caption text-warning-fg" data-conflict-note>
            {dgettext("ui", "对话期间已被改为 %{current}，草稿保留 %{draft}",
              current: short(@base[field]),
              draft: short(@squad[field])
            )}
          </p>
        </li>
        <li
          id="edit-field-members"
          data-changed={@members != nil && "true"}
          data-conflict={"members" in @design.conflicts && "true"}
          class={["flex min-w-0 flex-col gap-1 py-1.5", @members && "border-l-2 border-l-brand pl-2"]}
        >
          <div class="flex items-center gap-2">
            <span class="text-caption text-fg-muted">{AgentDesignSquad.field_label("members")}</span>
            <.button
              :if={@members}
              id="edit-revert-members"
              size="xs"
              variant="ghost"
              class="ml-auto"
              phx-click="edit_revert"
              phx-value-part="squad"
              phx-value-field="members"
              disabled_reason={@locked}
            >
              {dgettext("ui", "恢复")}
            </.button>
          </div>
          <ul class="flex flex-col gap-0.5">
            <li
              :for={m <- List.wrap(@squad["members"])}
              class="flex min-w-0 items-center gap-2 text-body"
              data-member={m["name"]}
            >
              <span class="min-w-0 truncate font-mono text-fg">{m["name"]}</span>
              <span
                :if={(m["role_note"] || "") != ""}
                class="min-w-0 truncate text-caption text-fg-muted"
              >{m["role_note"]}</span>
              <.badge
                :if={MapSet.member?(@added, String.downcase(m["name"]))}
                tone={:success}
                data-mark="added"
              >
                {dgettext("ui", "新增")}
              </.badge>
              <.badge
                :if={MapSet.member?(@noted, String.downcase(m["name"]))}
                tone={:info}
                data-mark="note"
              >
                {dgettext("ui", "说明已改")}
              </.badge>
            </li>
            <li :for={name <- @removed} class="flex items-center gap-2 text-body" data-member={name}>
              <span class="font-mono text-fg-muted line-through">{name}</span>
              <.badge tone={:danger} data-mark="removed">{dgettext("ui", "移除")}</.badge>
            </li>
          </ul>
        </li>
      </ul>
    </article>
    """
  end

  defp squad_errors(errors), do: for({field, msgs} <- errors, msg <- msgs, do: {field, msg})

  defp short(nil), do: ""

  defp short(text) when is_binary(text) do
    if String.length(text) > 40, do: String.slice(text, 0, 40) <> "…", else: text
  end

  defp short(value), do: to_string(value)

  ## The confirmation

  attr :snapshot, :map, required: true
  attr :lookup, :map, required: true

  @doc "What 「应用修改」 writes: each change, the new agents, the risky ones marked."
  def confirm_body(assigns) do
    ~H"""
    <div class="flex flex-col gap-3">
      <ul id="design-confirm-list" class="flex flex-col gap-1">
        <li
          :for={c <- @snapshot.changes}
          class="flex flex-wrap items-center gap-2 text-body"
          data-field={c.field}
          data-risky={risky?(c) && "true"}
        >
          <span class="text-fg-muted">{change_label(@snapshot, c.field)}</span>
          <span :if={c[:hunks]} class="tabular-nums text-fg">
            {line_counts(c.hunks)}
          </span>
          <span :if={c.field == "members"} class="text-fg">{members_text(c)}</span>
          <span :if={!c[:hunks] and c.field != "members"} class="text-fg">
            {plain(c.field, c.from, @lookup)} → {plain(c.field, c.to, @lookup)}
          </span>
          <.badge :if={risky?(c)} tone={:warning}>{risk_text(c)}</.badge>
        </li>
        <li
          :for={a <- @snapshot.agents}
          class="flex flex-wrap items-center gap-2"
          data-name={a["name"]}
        >
          <.badge tone={:success}>{dgettext("ui", "新建")}</.badge>
          <span class="font-mono text-body text-fg">{a["name"]}</span>
          <.badge tone={:muted}>{provider_label(a["provider"])}</.badge>
          <.badge :if={List.wrap(a["mcp_servers"]) != []} tone={:warning}>
            {dgettext("ui", "新增 MCP：%{names}", names: Enum.join(a["mcp_servers"], ", "))}
          </.badge>
        </li>
      </ul>
      <p class="text-body text-fg-muted">
        {dgettext("ui", "只写入这些修改；环境变量、额外 MCP 服务器与追加参数不变。")}
      </p>
    </div>
    """
  end

  defp change_label(%{target: %{kind: :squad}}, field), do: AgentDesignSquad.field_label(field)
  defp change_label(_snapshot, field), do: field_label(field)

  defp line_counts(hunks) do
    %{added: a, removed: r} = counts(Enum.flat_map(hunks, & &1.lines))
    dgettext("ui", "+%{a} −%{r} 行", a: a, r: r)
  end

  defp members_text(c) do
    [
      c.added != [] && dgettext("ui", "新增 %{names}", names: Enum.join(c.added, "、")),
      c.removed != [] && dgettext("ui", "移除 %{names}", names: Enum.join(c.removed, "、")),
      c.notes != [] && dgettext("ui", "说明已改 %{names}", names: Enum.join(c.notes, "、"))
    ]
    |> Enum.filter(& &1)
    |> Enum.join("；")
  end

  defp plain("runtime_id", nil, _lookup), do: dgettext("ui", "不绑定")

  defp plain("runtime_id", id, lookup),
    do: value_text("runtime_id", %{"runtime_id" => id}, lookup)

  defp plain("provider_account_id", %{"name" => _} = account, lookup),
    do: value_text("provider_account_id", %{"provider_account" => account}, lookup)

  defp plain("provider_account_id", id, lookup),
    do: value_text("provider_account_id", %{"provider_account_id" => id}, lookup)

  defp plain(field, value, lookup)
       when field in ~w(provider access capabilities model effort mcp_servers),
       do: value_text(field, %{field => value}, lookup)

  defp plain(_field, nil, _lookup), do: dgettext("ui", "无")
  defp plain(_field, value, _lookup), do: to_string(value)

  defp risky?(c), do: risk_text(c) != nil

  defp risk_text(%{field: "access", to: "workspace"}), do: dgettext("ui", "工作区所有成员都能触发")

  defp risk_text(%{field: "capabilities", from: from, to: to}) do
    if "create_tasks" in List.wrap(to) and "create_tasks" not in List.wrap(from),
      do: dgettext("ui", "可以建任务")
  end

  defp risk_text(%{field: "mcp_servers", from: from, to: to}) do
    added = List.wrap(to) -- List.wrap(from)
    if added != [], do: dgettext("ui", "新增 MCP：%{names}", names: Enum.join(added, ", "))
  end

  defp risk_text(%{field: "runtime_id", to: nil}), do: dgettext("ui", "解绑：排队中的运行会被取消")
  defp risk_text(%{field: "runtime_id"}), do: dgettext("ui", "换运行时")
  defp risk_text(%{field: "provider_account_id", to: nil}), do: dgettext("ui", "解绑供应商账号")
  defp risk_text(%{field: "provider_account_id"}), do: dgettext("ui", "换供应商账号")
  defp risk_text(_change), do: nil

  defp same?(a, b) when is_binary(a) and is_binary(b),
    do: String.downcase(a) == String.downcase(b)

  defp same?(_a, _b), do: false

  @doc false
  def long_fields, do: @long
end
