defmodule HelmsmanWeb.AgentDesignComponents do
  @moduledoc """
  Pieces of the agent design page (add-agent-conversation-ui D4, D6, D8, D11): messages
  and their draft edits, the helper chip and options, the draft cards and the list of
  the confirmation dialog. Every text the AI or the user wrote (replies, names,
  instructions) is shown as written: replies and instructions through the sanitising
  `markdown/1`, everything else escaped.
  """
  use HelmsmanWeb, :html

  import HelmsmanWeb.AgentComponents, only: [provider_label: 1]
  import HelmsmanWeb.RunComponents, only: [cost_text: 1, failure_label: 1, tokens: 1]

  alias HelmsmanWeb.RunComponents

  ## Texts (D11)

  @doc "The localized name of a draft field (edit records, confirmation errors)."
  def field_label("name"), do: dgettext("ui", "名字")
  def field_label("provider"), do: "CLI"
  def field_label("description"), do: dgettext("ui", "描述")
  def field_label("runtime_id"), do: dgettext("ui", "运行时")
  def field_label("provider_account_id"), do: dgettext("ui", "供应商账号")
  def field_label("model"), do: dgettext("ui", "模型")
  def field_label("effort"), do: dgettext("ui", "推理强度")
  def field_label("instructions"), do: dgettext("ui", "指令")
  def field_label("capabilities"), do: dgettext("ui", "能力")
  def field_label("access"), do: dgettext("ui", "谁能触发")
  def field_label("max_concurrency"), do: dgettext("ui", "并发上限")
  def field_label("timeout_minutes"), do: dgettext("ui", "总时长")
  def field_label("idle_timeout_minutes"), do: dgettext("ui", "无输出时长")
  def field_label(field) when is_atom(field), do: field_label(Atom.to_string(field))
  def field_label(field), do: field

  @doc """
  The draft edits of a user message or the pending edits, as text pieces:
  `{changed, removed}` — 「fe-dev（模型、推理强度）」 and the removed agents' names.
  """
  def edit_parts(edits) do
    edits = List.wrap(edits)

    # The squad part of a squad conversation (add-squads-autopilots-ui D16):
    # 「小队（成员）」.
    squad =
      for %{"squad" => true} = edit <- edits do
        case List.wrap(edit["fields"]) do
          [] ->
            dgettext("ui", "小队")

          fields ->
            dgettext("ui", "小队（%{fields}）",
              fields: Enum.map_join(fields, "、", &HelmsmanWeb.AgentDesignSquad.field_label/1)
            )
        end
      end

    changed =
      for %{"agent" => agent} = edit <- edits, edit["removed"] != true do
        fields = Enum.reject(List.wrap(edit["fields"]), &(&1 == "name"))

        cond do
          edit["added"] -> dgettext("ui", "%{agent}（新增）", agent: agent)
          fields == [] -> agent
          true -> "#{agent}（#{Enum.map_join(fields, "、", &field_label/1)}）"
        end
      end

    removed = for %{"agent" => agent, "removed" => true} <- edits, do: agent
    {squad ++ changed, removed}
  end

  @doc "「你修改了草稿：…；移除了 …」, or nil without edits."
  def edits_text(edits) do
    case edit_parts(edits) do
      {[], []} ->
        nil

      {changed, removed} ->
        [
          changed != [] && dgettext("ui", "你修改了草稿：%{list}", list: Enum.join(changed, "；")),
          removed != [] && dgettext("ui", "移除了 %{list}", list: Enum.join(removed, "、"))
        ]
        |> Enum.filter(& &1)
        |> Enum.join("；")
    end
  end

  @doc "The text of a system message (by `code`)."
  def system_text(%{code: "stopped"}, _helper), do: dgettext("ui", "已停止这一轮")

  def system_text(%{code: "queue_timeout"}, helper),
    do: dgettext("ui", "%{helper} 10 分钟内没有开始（可能正忙或离线），这一轮已取消", helper: helper)

  def system_text(%{code: "failed"} = message, _helper),
    do: dgettext("ui", "这一轮失败：%{reason}", reason: failure_label(message[:detail]))

  def system_text(%{code: "cancelled"}, _helper), do: dgettext("ui", "这一轮被取消")

  def system_text(%{code: "no_reply"}, helper),
    do: dgettext("ui", "%{helper} 没有回复文字", helper: helper)

  def system_text(%{code: "helper_changed"} = message, _helper),
    do: dgettext("ui", "起草 Agent 换成了 %{name}", name: message[:detail])

  def system_text(_message, _helper), do: dgettext("ui", "系统消息")

  defp system_icon("stopped"), do: "lucide-circle-stop"
  defp system_icon("queue_timeout"), do: "lucide-hourglass"
  defp system_icon("failed"), do: "lucide-circle-x"
  defp system_icon("helper_changed"), do: "lucide-repeat"
  defp system_icon(_code), do: "lucide-info"

  @doc "Text of a domain error of the conversation functions (D11)."
  def error_text(:draft_full, _helper), do: dgettext("ui", "草稿最多 8 个 Agent")

  def error_text(:turn_running, helper),
    do: dgettext("ui", "%{helper} 正在回复，等这一轮结束", helper: helper)

  def error_text(:turn_limit, _helper), do: dgettext("ui", "已达 40 条消息上限")
  def error_text(:design_closed, _helper), do: dgettext("ui", "这个对话已结束")
  def error_text(:stale, _helper), do: dgettext("ui", "草稿刚被更新")
  def error_text(:empty_draft, _helper), do: dgettext("ui", "草稿里还没有 Agent")
  def error_text(:not_found, _helper), do: dgettext("ui", "对话不存在")
  def error_text(:forbidden, _helper), do: dgettext("ui", "没有权限")

  def error_text({:referenced_by_squad, name}, _helper),
    do: HelmsmanWeb.AgentDesignSquad.referenced_text(name)

  def error_text(reason, helper) when is_atom(reason) do
    case RunComponents.unavailable_reason(helper || "", {:skipped, reason}) do
      nil -> dgettext("ui", "操作失败，请重试")
      text -> text
    end
  end

  def error_text(_reason, _helper), do: dgettext("ui", "操作失败，请重试")

  @doc "The usage line of the conversation (「输入 12.3k · 输出 2.1k · $0.04」), nil when zero."
  def usage_text(%{input_tokens: input, output_tokens: output} = usage)
      when input > 0 or output > 0 do
    base =
      dgettext("ui", "输入 %{input} · 输出 %{output}", input: tokens(input), output: tokens(output))

    cost = usage[:cost] || 0
    if is_number(cost) and cost > 0, do: base <> " · " <> cost_text(cost), else: base
  end

  def usage_text(_usage), do: nil

  @doc "The owner of a helper as shown: 「你」 for the current user."
  def owner_name(%{owner: %{user_id: id}}, %{user: %{id: id}}), do: dgettext("ui", "你")
  def owner_name(%{owner: %{name: name}}, _scope), do: name

  @doc "Why the helper cannot run now (nil when it can)."
  def helper_reason(%{name: name, dispatchability: d}),
    do: RunComponents.unavailable_reason(name, d)

  @doc """
  Orders helpers for the selections (D3): dispatchable first, the user's own first, then
  by name.
  """
  def sort_helpers(helpers, scope) do
    Enum.sort_by(helpers, fn h ->
      {h.dispatchability != :ok, h.owner.user_id != scope.user.id, String.downcase(h.name)}
    end)
  end

  ## Messages (D4)

  attr :message, :map, required: true
  attr :helper, :map, required: true
  attr :scope, :map, required: true

  def message(%{message: %{role: :user}} = assigns) do
    assigns = assign(assigns, :edits, edits_text(assigns.message[:edits]))

    ~H"""
    <div class="flex flex-col items-end gap-1" data-role="user">
      <p :if={@edits} class="max-w-[85%] text-right text-caption text-fg-muted" data-edits>
        {@edits}
      </p>
      <div
        phx-no-format
        class="max-w-[85%] whitespace-pre-wrap break-words rounded-box bg-selected px-3 py-2 text-body text-fg"
      >{@message.content}</div>
    </div>
    """
  end

  def message(%{message: %{role: :assistant}} = assigns) do
    ~H"""
    <div class="flex items-start gap-2" data-role="assistant">
      <.actor_chip actor={%{name: @helper.name, kind: :agent}} compact />
      <div class="min-w-0 max-w-[85%] rounded-box border border-border bg-surface px-3 py-2">
        <.markdown
          content={@message.content || ""}
          scope={@scope}
          anchor_ns={"design-msg-#{@message.seq}"}
        />
        <.link
          :if={@message[:run_id]}
          navigate={~p"/w/#{@scope.workspace.slug}/runs/#{@message.run_id}"}
          class="mt-1 inline-flex items-center gap-1 text-caption text-fg-muted hover:text-fg hover:underline"
          data-run-link
        >
          <.icon name="lucide-file-text" class="size-3" />{dgettext("ui", "执行记录")}
        </.link>
      </div>
    </div>
    """
  end

  def message(assigns) do
    assigns =
      assign(assigns,
        text: system_text(assigns.message, assigns.helper.name),
        icon: system_icon(assigns.message[:code])
      )

    ~H"""
    <div
      class={[
        "flex items-center justify-center gap-1.5 text-center text-caption",
        if(@message[:code] == "failed", do: "text-danger-fg", else: "text-fg-muted")
      ]}
      data-role="system"
      data-code={@message[:code]}
    >
      <.icon name={@icon} class="size-3.5 shrink-0" />
      <span>{@text}</span>
      <.link
        :if={@message[:code] == "failed" and @message[:run_id]}
        navigate={~p"/w/#{@scope.workspace.slug}/runs/#{@message.run_id}"}
        class="font-medium underline"
        data-run-link
      >
        {dgettext("ui", "执行记录")}
      </.link>
    </div>
    """
  end

  ## Draft cards (D6)

  attr :agent, :map, required: true, doc: "the draft agent (string keys)"
  attr :index, :integer, required: true

  attr :lookup, :map,
    required: true,
    doc: "%{runtimes: %{id => runtime}, accounts: %{id => account}}"

  attr :errors, :list, default: [], doc: "[{field, message}] of a refused confirmation"
  attr :locked, :string, default: nil, doc: "why the card cannot be edited now"

  attr :remove_reason, :string,
    default: nil,
    doc: "why the card cannot be removed (the squad refers to it)"

  attr :highlight, :string, default: nil, doc: "a class that replays the highlight"
  attr :scope, :map, required: true

  def draft_card(assigns) do
    a = assigns.agent

    assigns =
      assign(assigns,
        runtime: runtime_text(a["runtime_id"], assigns.lookup.runtimes),
        account: account_text(a, assigns.lookup.accounts),
        account?: a["provider"] in ~w(claude codex),
        model: model_text(a),
        workspace?: a["access"] == "workspace",
        create_tasks?: "create_tasks" in List.wrap(a["capabilities"]),
        size: byte_text(byte_size(a["instructions"] || ""))
      )

    ~H"""
    <article
      id={"draft-agent-#{@index}"}
      data-name={@agent["name"]}
      class={[
        "flex min-w-0 flex-col gap-2 rounded-box border bg-surface p-3",
        if(@errors != [], do: "border-danger", else: "border-border"),
        @highlight
      ]}
    >
      <div class="flex min-w-0 flex-wrap items-center gap-2">
        <span class="min-w-0 truncate font-mono text-body font-semibold text-fg" data-field="name">
          {@agent["name"]}
        </span>
        <.badge tone={:muted} data-field="provider">{provider_label(@agent["provider"])}</.badge>
        <.badge :if={@agent["updated_by"] == "ai"} tone={:info} data-updated-by="ai">
          {dgettext("ui", "AI 修改")}
        </.badge>
        <.badge :if={@agent["updated_by"] == "user"} tone={:brand} data-updated-by="user">
          {dgettext("ui", "你修改")}
        </.badge>
        <span class="ml-auto flex shrink-0 items-center gap-1">
          <.icon_button
            id={"draft-agent-#{@index}-edit"}
            icon="lucide-pencil"
            size="sm"
            label={dgettext("ui", "编辑")}
            phx-click="edit_agent"
            phx-value-name={@agent["name"]}
            disabled_reason={@locked}
          />
          <.icon_button
            id={"draft-agent-#{@index}-remove"}
            icon="lucide-trash"
            size="sm"
            label={dgettext("ui", "移除")}
            phx-click="ask_remove"
            phx-value-name={@agent["name"]}
            disabled_reason={@locked || @remove_reason}
          />
        </span>
      </div>

      <ul
        :if={@errors != []}
        id={"draft-agent-#{@index}-errors"}
        role="alert"
        class="flex flex-col text-caption text-danger-fg"
      >
        <li :for={{field, msg} <- @errors}>{field_label(field)}：{msg}</li>
      </ul>

      <p
        :if={(@agent["description"] || "") != ""}
        class="truncate text-body text-fg-muted"
        title={@agent["description"]}
        data-field="description"
      >
        {@agent["description"]}
      </p>

      <.property_list>
        <.property_row label={dgettext("ui", "运行时")} data-field="runtime_id">
          <span class={["truncate", @runtime.warn && "text-warning-fg"]}>{@runtime.text}</span>
        </.property_row>
        <.property_row
          :if={@account?}
          label={dgettext("ui", "供应商账号")}
          data-field="provider_account_id"
        >
          <span class={["truncate", @account.warn && "text-warning-fg"]}>{@account.text}</span>
        </.property_row>
        <.property_row label={dgettext("ui", "模型")} data-field="model">
          <span class="truncate font-mono text-label text-fg">{@model}</span>
        </.property_row>
        <.property_row
          label={dgettext("ui", "推理强度")}
          value={@agent["effort"]}
          placeholder={dgettext("ui", "缺省")}
          data-field="effort"
        />
        <.property_row label={dgettext("ui", "谁能触发")} data-field="access">
          <.badge :if={@workspace?} tone={:warning} data-warn="access">
            {dgettext("ui", "工作区所有成员")}
          </.badge>
          <span :if={!@workspace?} class="text-fg">{dgettext("ui", "仅你")}</span>
        </.property_row>
        <.property_row label={dgettext("ui", "能力")} data-field="capabilities">
          <.badge :if={@create_tasks?} tone={:warning} data-warn="create_tasks">
            {dgettext("ui", "可以建任务")}
          </.badge>
          <span :if={!@create_tasks?} class="text-fg-muted">{dgettext("ui", "只能更新自己的任务")}</span>
        </.property_row>
        <.property_row
          label={dgettext("ui", "限制")}
          value={limits_text(@agent)}
          data-field="limits"
        />
      </.property_list>

      <p :if={@workspace?} class="text-caption text-warning-fg" data-warn-note="access">
        {dgettext("ui", "工作区所有成员都能触发这个 Agent，在你的机器上运行")}
      </p>
      <p :if={@create_tasks?} class="text-caption text-warning-fg" data-warn-note="create_tasks">
        {dgettext("ui", "它能在工作区里新建任务并指派")}
      </p>

      <details :if={(@agent["instructions"] || "") != ""} data-field="instructions">
        <summary class="cursor-pointer text-label text-fg-muted">
          {dgettext("ui", "指令（%{size}）", size: @size)}
        </summary>
        <div class="mt-2 border-t border-border pt-2">
          <.markdown
            content={@agent["instructions"]}
            scope={@scope}
            anchor_ns={"draft-#{@index}"}
          />
        </div>
      </details>
    </article>
    """
  end

  defp runtime_text(nil, _runtimes), do: %{text: dgettext("ui", "不绑定"), warn: false}

  defp runtime_text(id, runtimes) do
    case runtimes[id] do
      %{disabled: false} = r ->
        status = if r.status == "online", do: dgettext("ui", "在线"), else: dgettext("ui", "离线")
        %{text: "#{r.daemon.name} · #{status}", warn: r.status != "online"}

      _ ->
        %{text: dgettext("ui", "运行时 #%{id}（不可用）", id: id), warn: true}
    end
  end

  defp account_text(%{"provider_account_id" => nil}, _accounts),
    do: %{text: dgettext("ui", "CLI 默认登录"), warn: false}

  defp account_text(%{"provider_account_id" => id}, accounts) when is_integer(id) do
    case accounts[id] do
      %{name: name} -> %{text: name, warn: false}
      _ -> %{text: dgettext("ui", "账号 #%{id}（不可用）", id: id), warn: true}
    end
  end

  defp account_text(_agent, _accounts), do: %{text: dgettext("ui", "CLI 默认登录"), warn: false}

  defp model_text(%{"model" => model}) when is_binary(model) and model != "", do: model

  defp model_text(agent),
    do:
      if(agent["provider_account_id"],
        do: dgettext("ui", "账号缺省"),
        else: dgettext("ui", "CLI 缺省")
      )

  defp limits_text(agent) do
    dgettext("ui", "并发 %{n} · 总时长 %{t} 分钟 · 无输出 %{i} 分钟",
      n: agent["max_concurrency"],
      t: agent["timeout_minutes"],
      i: agent["idle_timeout_minutes"]
    )
  end

  @doc "「512 B」 / 「1.2 KB」."
  def byte_text(bytes) when bytes < 1024, do: "#{bytes} B"

  def byte_text(bytes),
    do: :erlang.float_to_binary(bytes / 1024, decimals: 1) <> " KB"

  @doc "「1.2 KB / 8 KB」 of a message being typed."
  def message_size(bytes, max), do: "#{byte_text(bytes)} / #{div(max, 1024)} KB"

  ## Confirmation (D8, D14)

  attr :agents, :list, required: true
  attr :squad, :map, default: nil, doc: "the squad part of a squad conversation's snapshot"
  attr :summary, :map, default: nil, doc: "its `trigger_summary`"

  @doc "The list of the confirmation dialog; a squad conversation's squad comes first (D16)."
  def confirm_list(assigns) do
    assigns =
      assign(assigns, :keys, MapSet.new(assigns.agents, &String.downcase(&1["name"] || "")))

    ~H"""
    <ul id="design-confirm-list" class="flex flex-col gap-1">
      <li :if={@squad} data-squad>
        <HelmsmanWeb.AgentDesignSquad.confirm_row squad={@squad} summary={@summary} keys={@keys} />
      </li>
      <li :for={a <- @agents} class="flex flex-wrap items-center gap-2" data-name={a["name"]}>
        <span class="font-mono text-body text-fg">{a["name"]}</span>
        <.badge tone={:muted}>{provider_label(a["provider"])}</.badge>
        <.badge :if={a["access"] == "workspace"} tone={:warning} data-warn="access">
          {dgettext("ui", "工作区所有成员")}
        </.badge>
        <.badge
          :if={"create_tasks" in List.wrap(a["capabilities"])}
          tone={:warning}
          data-warn="create_tasks"
        >
          {dgettext("ui", "可以建任务")}
        </.badge>
      </li>
    </ul>
    """
  end
end
