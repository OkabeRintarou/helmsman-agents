defmodule HelmsmanWeb.RunComponents do
  @moduledoc """
  Run texts and pieces (add-agents-runs-ui D2, D12, D13): dispatch outcome messages,
  trigger and failure labels, usage and duration formats, and the run card.
  """
  use HelmsmanWeb, :html

  require Logger

  import HelmsmanWeb.ProviderAccountComponents, only: [account_icon: 1]

  alias HelmsmanWeb.Url

  ## Dispatch outcomes (D12)

  @known_reasons ~w(not_started task_closed unauthorized agent_disabled agent_archived no_runtime
                    runtime_disabled daemon_outdated loop_detected chain_too_long rate_limited
                    squad_disabled)a

  @doc """
  The flash of a dispatch outcome (`%Helmsman.Runs.Outcome{}` or a map with `agent`,
  `result`, `reason`, and `blocked_by` for `deferred` — add-dependency-dispatch: the
  agent was assigned and starts once the blocking tasks are done):
  `{:info | :warning, text}`. An unknown result is logged and shown as assigned.
  """
  def dispatch_message(%{agent: agent, result: result} = outcome) do
    case Map.get(outcome, :squad) do
      squad when is_binary(squad) -> squad_message(squad, agent, outcome)
      _ -> agent_message(agent, result, outcome)
    end
  end

  # A squad's leader run (add-squads-autopilots-ui D6): `agent` is the leader.
  defp squad_message(squad, leader, %{result: result} = outcome) do
    case {to_atom(result), to_atom(Map.get(outcome, :reason))} do
      {:queued, _} ->
        {:info, dgettext("ui", "已派发给 %{squad}（leader %{leader}）", squad: squad, leader: leader)}

      {:merged, _} ->
        agent_message(leader, result, outcome)

      {:skipped, reason} when reason != :not_started ->
        {:warning, squad_not_started(squad, leader, reason, Map.get(outcome, :refused) || [])}

      _ ->
        agent_message(squad, result, outcome)
    end
  end

  defp squad_not_started(squad, _leader, :unauthorized, refused) do
    names = if refused == [], do: squad, else: Enum.join(refused, "、")
    dgettext("ui", "没有启动 %{squad}：你无权触发 %{names}", squad: squad, names: names)
  end

  defp squad_not_started(squad, _leader, :squad_disabled, _refused),
    do: dgettext("ui", "没有启动 %{squad}：小队已停用", squad: squad)

  defp squad_not_started(squad, leader, reason, _refused) do
    case reason_text(leader, reason) do
      nil -> dgettext("ui", "没有启动 %{agent}", agent: squad)
      text -> dgettext("ui", "没有启动 %{agent}：%{reason}", agent: squad, reason: text)
    end
  end

  defp agent_message(agent, result, outcome) do
    case to_atom(result) do
      :queued ->
        {:info, dgettext("ui", "已派发给 %{agent}", agent: agent)}

      :merged ->
        {:info, dgettext("ui", "已并入 %{agent} 排队中的运行", agent: agent)}

      :skipped ->
        case to_atom(Map.get(outcome, :reason)) do
          :not_started -> {:info, dgettext("ui", "已指派给 %{agent}，暂不开始", agent: agent)}
          reason -> {:warning, not_started(agent, reason)}
        end

      :deferred ->
        {:info, deferred(agent, Map.get(outcome, :blocked_by) || [])}

      other ->
        Logger.warning("unknown dispatch result: #{inspect(other)}")
        {:info, dgettext("ui", "已指派给 %{agent}", agent: agent)}
    end
  end

  defp deferred(agent, []),
    do: dgettext("ui", "已指派给 %{agent}，等前置任务完成后开始", agent: agent)

  defp deferred(agent, blocked_by),
    do:
      dgettext("ui", "已指派给 %{agent}，等 %{tasks} 完成后开始",
        agent: agent,
        tasks: Enum.join(blocked_by, "、")
      )

  @doc """
  The flash of a task's `dispatch` list: `nil` when empty, otherwise one message joined
  with「；」whose level is `:warning` when any part is one.
  """
  def dispatch_flash([]), do: nil
  def dispatch_flash(nil), do: nil

  def dispatch_flash(outcomes) when is_list(outcomes) do
    messages = Enum.map(outcomes, &dispatch_message/1)
    level = if Enum.any?(messages, &(elem(&1, 0) == :warning)), do: :warning, else: :info
    {level, Enum.map_join(messages, "；", &elem(&1, 1))}
  end

  defp not_started(agent, reason) do
    case reason_text(agent, reason) do
      nil ->
        Logger.warning("unknown dispatch reason: #{inspect(reason)}")
        dgettext("ui", "没有启动 %{agent}", agent: agent)

      text ->
        dgettext("ui", "没有启动 %{agent}：%{reason}", agent: agent, reason: text)
    end
  end

  @doc """
  Why a trigger of `agent` started nothing, from the `reason` of a dispatch outcome
  (atom or string); `nil` for a reason the page does not know.
  """
  def skip_reason(agent, reason), do: reason_text(agent, to_atom(reason))

  defp reason_text(_agent, :task_closed), do: dgettext("ui", "任务不在新建或进行中")
  defp reason_text(_agent, :unauthorized), do: dgettext("ui", "你无权触发它")
  defp reason_text(_agent, :agent_disabled), do: dgettext("ui", "它已停用")
  defp reason_text(_agent, :agent_archived), do: dgettext("ui", "它已归档")
  defp reason_text(_agent, :no_runtime), do: dgettext("ui", "它没有绑定运行时")
  defp reason_text(_agent, :runtime_disabled), do: dgettext("ui", "运行时已禁用")

  defp reason_text(_agent, :daemon_outdated),
    do: dgettext("ui", "它所在机器的守护进程版本过旧，请升级 helmsman 守护进程")

  defp reason_text(agent, :loop_detected),
    do: dgettext("ui", "%{agent} 已在触发链上，为防止循环没有启动", agent: agent)

  defp reason_text(_agent, :chain_too_long), do: dgettext("ui", "触发链过长，为防止循环没有启动")
  defp reason_text(_agent, :rate_limited), do: dgettext("ui", "这个任务一小时内的运行次数已达上限")
  defp reason_text(_agent, _reason), do: nil

  @doc """
  The short reason an agent cannot be dispatched (menus, the 运行 button), from
  `{:skipped, reason}` of `HelmsmanWeb.RunData.availability/1`; `nil` for `:ok`.
  """
  def unavailable_reason(_agent, :ok), do: nil

  def unavailable_reason(agent, {:skipped, :unauthorized}),
    do: dgettext("ui", "你无权触发 %{agent}", agent: agent)

  def unavailable_reason(agent, {:skipped, :agent_disabled}),
    do: dgettext("ui", "%{agent} 已停用", agent: agent)

  def unavailable_reason(agent, {:skipped, :agent_archived}),
    do: dgettext("ui", "%{agent} 已归档", agent: agent)

  def unavailable_reason(agent, {:skipped, :no_runtime}),
    do: dgettext("ui", "%{agent} 没有绑定运行时", agent: agent)

  def unavailable_reason(agent, {:skipped, :runtime_disabled}),
    do: dgettext("ui", "%{agent} 的运行时已禁用", agent: agent)

  def unavailable_reason(agent, {:skipped, :daemon_outdated}),
    do: dgettext("ui", "%{agent} 所在机器的守护进程版本过旧", agent: agent)

  def unavailable_reason(agent, {:skipped, _}), do: dgettext("ui", "不能启动 %{agent}", agent: agent)

  defp to_atom(value) when is_atom(value), do: value

  defp to_atom(value) when is_binary(value) do
    Enum.find(
      @known_reasons ++ [:queued, :merged, :skipped, :deferred],
      value,
      &(Atom.to_string(&1) == value)
    )
  end

  ## Triggers and failures (D13)

  @doc "Name of a trigger kind (`auto: true` retries are 自动重试)."
  def trigger_kind(%{kind: "retry", auto: true}), do: dgettext("ui", "自动重试")
  def trigger_kind(%{kind: kind}), do: kind_name(to_string(kind))

  defp kind_name("assign"), do: dgettext("ui", "指派")
  defp kind_name("manual"), do: dgettext("ui", "手动运行")
  defp kind_name("retry"), do: dgettext("ui", "重试")
  defp kind_name("reopen"), do: dgettext("ui", "打回")
  defp kind_name("resubmit"), do: dgettext("ui", "重新提交")
  defp kind_name("answer"), do: dgettext("ui", "回答")
  defp kind_name("mention"), do: dgettext("ui", "提及")
  defp kind_name("requested"), do: dgettext("ui", "回调提出方")
  defp kind_name("steer"), do: dgettext("ui", "插话")
  defp kind_name("unblocked"), do: dgettext("ui", "依赖满足")
  defp kind_name("delegate"), do: dgettext("ui", "委派")
  defp kind_name("delegated"), do: dgettext("ui", "委派")
  defp kind_name("delegate_done"), do: dgettext("ui", "委派完成")
  defp kind_name("epic_stalled"), do: dgettext("ui", "Epic 停滞")
  defp kind_name("autopilot"), do: dgettext("ui", "自动化")
  defp kind_name("design"), do: dgettext("ui", "创建对话")
  defp kind_name(_), do: dgettext("ui", "其他触发")

  @doc "「<触发者> <种类>」of one trigger (「自动重试」 alone)."
  def trigger_label(%{kind: "retry", auto: true} = trigger), do: trigger_kind(trigger)

  # A creation conversation is only its user's: the label never names or links it.
  def trigger_label(%{kind: kind} = trigger) when kind in ["design", :design] do
    case trigger[:by] do
      %{name: name} -> dgettext("ui", "%{name} 的创建对话", name: name)
      _ -> trigger_kind(trigger)
    end
  end

  # The leader is woken up when a member's delegated run ends (add-squads-autopilots-ui D7).
  def trigger_label(%{kind: kind} = trigger) when kind in ["delegate_done", :delegate_done] do
    case trigger[:member] do
      %{name: name} -> dgettext("ui", "%{name} 的委派运行结束", name: name)
      _ -> trigger_kind(trigger)
    end
  end

  # The stall wake-up is the system's: no actor (improve-squad-leader-orchestration D19).
  def trigger_label(%{kind: kind} = trigger) when kind in ["epic_stalled", :epic_stalled],
    do: trigger_kind(trigger)

  def trigger_label(%{kind: kind} = trigger) when kind in ["autopilot", :autopilot] do
    source = autopilot_source(trigger[:source])

    case trigger[:autopilot] do
      %{name: name} -> dgettext("ui", "自动化 %{name}（%{source}）", name: name, source: source)
      _ -> dgettext("ui", "已删除的自动化（%{source}）", source: source)
    end
  end

  def trigger_label(trigger) do
    case trigger[:by] do
      %{name: name} -> "#{name} #{trigger_kind(trigger)}"
      _ -> trigger_kind(trigger)
    end
  end

  defp autopilot_source(source) when source in ["schedule", :schedule], do: dgettext("ui", "定时")
  defp autopilot_source(source) when source in ["manual", :manual], do: dgettext("ui", "手动")
  defp autopilot_source(source) when source in ["webhook", :webhook], do: "webhook"
  defp autopilot_source(_source), do: dgettext("ui", "触发")

  @doc "The page of the autopilot that started a run (its trigger), or nil (none, deleted)."
  def autopilot_path(%{kind: kind, autopilot: %{id: id}}, slug)
      when kind in ["autopilot", :autopilot],
      do: "/w/#{slug}/autopilots/#{id}"

  def autopilot_path(_trigger, _slug), do: nil

  @doc "Why an autopilot's run has no 重试."
  def not_retryable_autopilot,
    do: dgettext("ui", "自动化的运行不能重试，请在自动化页「立即运行」")

  @doc "Whether a run was started by an autopilot (run only: no task, never retried)."
  def autopilot_run?(run),
    do: Enum.any?(Map.get(run, :triggers) || [], &(to_string(&1[:kind]) == "autopilot"))

  @doc "The card's trigger text: the first trigger, plus「等 n 条触发」with more."
  def trigger_summary([]), do: ""
  def trigger_summary([first]), do: trigger_label(first)

  def trigger_summary([first | _] = triggers),
    do: dgettext("ui", "%{first} 等 %{n} 条触发", first: trigger_label(first), n: length(triggers))

  @failure_reasons ~w(runtime_offline daemon_restart lease_expired timeout stalled provider_network provider_rate_limit provider_auth provider_quota cli_missing cli_version workspace_prepare push_conflict push_failed context_overflow obsolete unauthorized cli_error unknown)

  @doc "Name of a failure reason (13 §5)."
  def failure_label(nil), do: nil
  def failure_label(reason) when is_atom(reason), do: failure_label(Atom.to_string(reason))
  def failure_label("runtime_offline"), do: dgettext("ui", "运行时离线")
  def failure_label("daemon_restart"), do: dgettext("ui", "守护进程重启")
  def failure_label("lease_expired"), do: dgettext("ui", "领取后未启动")
  def failure_label("timeout"), do: dgettext("ui", "超时")
  def failure_label("stalled"), do: dgettext("ui", "长时间无输出")
  def failure_label("provider_network"), do: dgettext("ui", "模型服务网络错误")
  def failure_label("provider_rate_limit"), do: dgettext("ui", "被限流")
  def failure_label("provider_auth"), do: dgettext("ui", "CLI 未登录")
  def failure_label("provider_quota"), do: dgettext("ui", "额度用尽")
  def failure_label("cli_missing"), do: dgettext("ui", "找不到 CLI")
  def failure_label("cli_version"), do: dgettext("ui", "CLI 版本过旧")
  def failure_label("workspace_prepare"), do: dgettext("ui", "准备工作目录失败")
  def failure_label("push_conflict"), do: dgettext("ui", "推送冲突")
  def failure_label("push_failed"), do: dgettext("ui", "推送失败")
  def failure_label("context_overflow"), do: dgettext("ui", "上下文超出")
  def failure_label("obsolete"), do: dgettext("ui", "已失效")
  def failure_label("unauthorized"), do: dgettext("ui", "授权已失效")
  def failure_label("cli_error"), do: dgettext("ui", "CLI 出错")
  def failure_label("unknown"), do: dgettext("ui", "未知错误")
  def failure_label(_reason), do: dgettext("ui", "未知错误")

  @doc "One-sentence explanation of a failure reason."
  def failure_hint(nil), do: nil
  def failure_hint(reason) when is_atom(reason), do: failure_hint(Atom.to_string(reason))
  def failure_hint("runtime_offline"), do: dgettext("ui", "运行时所在的机器离线或守护进程已停止")
  def failure_hint("daemon_restart"), do: dgettext("ui", "运行期间守护进程重启，CLI 被中断")
  def failure_hint("lease_expired"), do: dgettext("ui", "守护进程领取后没有按时启动 CLI")
  def failure_hint("timeout"), do: dgettext("ui", "运行超过了 Agent 的总时长上限")
  def failure_hint("stalled"), do: dgettext("ui", "CLI 超过无输出上限没有任何输出")
  def failure_hint("provider_network"), do: dgettext("ui", "CLI 无法连接模型服务，检查机器的网络后重试")
  def failure_hint("provider_rate_limit"), do: dgettext("ui", "模型服务限流，稍后重试")
  def failure_hint("provider_auth"), do: dgettext("ui", "在运行时所在的机器上登录这个 CLI 后重试")
  def failure_hint("provider_quota"), do: dgettext("ui", "模型服务的额度已用尽，充值或等额度恢复后重试")
  def failure_hint("cli_missing"), do: dgettext("ui", "运行时所在的机器上没有找到这个 CLI")
  def failure_hint("cli_version"), do: dgettext("ui", "升级运行时所在机器上的 CLI 后重试")
  def failure_hint("workspace_prepare"), do: dgettext("ui", "守护进程无法准备代码仓库或工作目录")
  def failure_hint("push_conflict"), do: dgettext("ui", "推送分支时与远端冲突")
  def failure_hint("push_failed"), do: dgettext("ui", "推送分支失败")
  def failure_hint("context_overflow"), do: dgettext("ui", "对话超出了模型的上下文长度")
  def failure_hint("obsolete"), do: dgettext("ui", "运行开始前任务、Agent 或运行时已变化，这次运行不再需要")
  def failure_hint("unauthorized"), do: dgettext("ui", "授权来源已无权触发这个 Agent")
  def failure_hint("cli_error"), do: dgettext("ui", "CLI 以错误结束，查看执行记录了解详情")
  def failure_hint("unknown"), do: dgettext("ui", "运行因未知原因失败")
  def failure_hint(_reason), do: nil

  @doc false
  def failure_reasons, do: @failure_reasons

  ## Formats (D13)

  @doc "A token count: 340, 1.2k, 3.4M."
  def tokens(nil), do: "0"
  def tokens(n) when n >= 1_000_000, do: one_decimal(n / 1_000_000) <> "M"
  def tokens(n) when n >= 1_000, do: one_decimal(n / 1_000) <> "k"
  def tokens(n), do: to_string(n)

  defp one_decimal(x), do: :erlang.float_to_binary(Float.round(x * 1.0, 1), decimals: 1)

  @doc "「输入 / 输出」tokens and the cost of a run's `usage`; `nil` without usage."
  def usage_text(nil), do: nil

  def usage_text(usage) when is_map(usage) do
    input = usage["input_tokens"] || usage[:input_tokens]
    output = usage["output_tokens"] || usage[:output_tokens]
    cost = usage["cost_usd"] || usage[:cost_usd]

    if is_nil(input) and is_nil(output) do
      nil
    else
      base = "#{tokens(input)} / #{tokens(output)}"
      if is_number(cost), do: base <> " · " <> cost_text(cost), else: base
    end
  end

  @doc "A cost in dollars, two decimals."
  def cost_text(cost), do: "$" <> :erlang.float_to_binary(cost * 1.0, decimals: 2)

  @doc "Total time of a run: from `started_at` (or `claimed_at`) to `finished_at`."
  def duration_text(run) do
    from = run[:started_at] || run[:claimed_at]

    case {from, run[:finished_at]} do
      {%DateTime{} = from, %DateTime{} = to} -> seconds_text(DateTime.diff(to, from, :second))
      _ -> nil
    end
  end

  @doc "「1 小时 3 分」「4 分 12 秒」「42 秒」."
  def seconds_text(secs) when secs >= 3600,
    do: dgettext("ui", "%{h} 小时 %{m} 分", h: div(secs, 3600), m: div(rem(secs, 3600), 60))

  def seconds_text(secs) when secs >= 60,
    do: dgettext("ui", "%{m} 分 %{s} 秒", m: div(secs, 60), s: rem(secs, 60))

  def seconds_text(secs), do: dgettext("ui", "%{s} 秒", s: max(secs, 0))

  @doc "The agent page of a run's agent."
  def agent_path(scope, name), do: Url.agent_path(scope.workspace.slug, name)

  ## Run card (D8)

  @doc "The time line of a run: 开始于 / 排队于 (relative) or the total duration."
  def time_kind(%{status: status}) when status in ~w(claimed running cancelling), do: :started
  def time_kind(%{status: status}) when status in ~w(queued deferred), do: :queued
  def time_kind(_run), do: :finished

  @doc """
  A run card (spec web-runs 运行卡片): status, agent, model (add-run-model), trigger summary with all triggers in
  a tooltip, attempt, time, usage, failure, authorizing user, retry links and actions.

  * `log` - patch path of 执行记录 (nil hides it)
  * `can_cancel` / `can_retry` - show 停止 / 重试 (the page decides with the status)
  """
  attr :id, :string, required: true
  attr :run, :map, required: true
  attr :scope, :map, required: true
  attr :log, :string, default: nil
  attr :can_cancel, :boolean, default: false
  attr :can_retry, :boolean, default: false
  attr :now, DateTime, default: nil
  attr :appearance, :map, default: %{}, doc: "the shell's `@appearance` (the Agent's mark)"

  def run_card(assigns) do
    run = assigns.run
    first = List.first(run.triggers || [])
    initiator = run[:initiator]

    assigns =
      assign(assigns,
        slug: assigns.scope.workspace.slug,
        time_kind: time_kind(run),
        first: first,
        authorizer:
          initiator && initiator[:name] &&
            (first == nil or get_in(first, [:by, :name]) != initiator.name) &&
            initiator.name,
        usage: usage_text(run[:usage])
      )

    ~H"""
    <article
      id={@id}
      class="flex flex-col gap-1.5 rounded-box border border-border bg-surface px-3 py-2.5"
      data-run-id={@run.id}
    >
      <div class="flex min-w-0 items-center gap-2">
        <.run_status_badge status={@run.status} />
        <.link
          navigate={agent_path(@scope, @run.agent)}
          class="flex min-w-0 items-center gap-1.5 text-body font-medium text-fg hover:underline"
          data-run-agent
        >
          <.actor_mark actor={Appearance.decorate(%{name: @run.agent, kind: :agent}, @appearance)} />
          <span class="truncate">{@run.agent}</span>
        </.link>
        <span :if={@run[:model]} class="flex min-w-0 text-caption text-fg-muted" data-run-model>
          <.model_label
            id={"#{@id}-model"}
            model={@run.model}
            account_icon={account_icon(@run[:provider_account])}
          />
        </span>
        <.link
          :if={@run[:squad]}
          navigate={Url.squad_path(@slug, @run.squad.name)}
          class="truncate text-caption text-fg-muted hover:underline"
          data-run-squad
        >
          {dgettext("ui", "以 %{squad} 的 leader 身份", squad: @run.squad.name)}
        </.link>
        <span class="ml-auto shrink-0 font-mono text-caption text-fg-subtle">#{@run.id}</span>
      </div>
      <div :if={@first} class="hm-tooltip-host relative flex w-fit" tabindex="0" data-run-triggers>
        <.link
          :if={autopilot_path(@first, @slug)}
          navigate={autopilot_path(@first, @slug)}
          class="text-caption text-fg-muted hover:underline"
          data-autopilot-link
        >
          {trigger_summary(@run.triggers)}
        </.link>
        <span :if={!autopilot_path(@first, @slug)} class="text-caption text-fg-muted">
          {trigger_summary(@run.triggers)}
        </span>
        <span role="tooltip" class={[tooltip_class(:bottom), "max-w-80"]} data-run-triggers-tip>
          <span :for={t <- @run.triggers} class="block">
            {trigger_label(t)}<span :if={t[:at]}> · {Calendar.strftime(t.at, "%m-%d %H:%M")}</span><span :if={
              t[:instructions]
            }>（{dgettext("ui", "说明：")}{t.instructions}）</span>
          </span>
        </span>
      </div>
      <div class="flex flex-wrap items-center gap-x-3 gap-y-1 text-caption text-fg-muted">
        <span :if={(@run[:attempt] || 1) > 1} data-run-attempt>
          {dgettext("ui", "第 %{n} 次尝试", n: @run.attempt)}
        </span>
        <span :if={@time_kind == :started} data-run-time>
          {dgettext("ui", "开始于")}
          <.relative_time
            id={"#{@id}-started"}
            at={@run[:started_at] || @run[:claimed_at] || @run.inserted_at}
            now={@now}
          />
        </span>
        <span :if={@time_kind == :queued} data-run-time>
          {dgettext("ui", "排队于")}
          <.relative_time id={"#{@id}-queued"} at={@run.inserted_at} now={@now} />
        </span>
        <span :if={@time_kind == :finished and duration_text(@run)} data-run-time>
          {duration_text(@run)}
        </span>
        <span :if={@usage} data-run-usage>{@usage}</span>
        <span
          :if={@run.failure_reason}
          class="hm-tooltip-host relative text-danger-fg"
          tabindex="0"
          data-run-failure
        >
          {failure_label(@run.failure_reason)}
          <span role="tooltip" class={tooltip_class(:bottom)}>{failure_hint(@run.failure_reason)}</span>
        </span>
        <span :if={@authorizer} data-run-authorizer>
          {dgettext("ui", "授权来源：%{name}", name: @authorizer)}
        </span>
        <.link
          :if={@run[:retry_of_id]}
          navigate={"/w/#{@slug}/runs/#{@run.retry_of_id}"}
          class="hover:underline"
          data-run-retry-of
        >
          {dgettext("ui", "重试自 #%{id}", id: @run.retry_of_id)}
        </.link>
        <.link
          :if={@run[:retry_run_id]}
          navigate={"/w/#{@slug}/runs/#{@run.retry_run_id}"}
          class="hover:underline"
          data-run-retried
        >
          {dgettext("ui", "已重试 → #%{id}", id: @run.retry_run_id)}
        </.link>
        <span :if={@run.status == "cancelling"} class="text-warning-fg">
          {dgettext("ui", "正在停止…")}
        </span>
        <span
          :if={@run.status in ["failed", "cancelled"] and autopilot_run?(@run)}
          data-run-not-retryable
        >
          {not_retryable_autopilot()}
        </span>
      </div>
      <div :if={@log || @can_cancel || @can_retry} class="flex items-center gap-1">
        <.button
          :if={@log}
          id={"#{@id}-log"}
          size="xs"
          variant="ghost"
          icon="lucide-scroll-text"
          patch={@log}
        >
          {dgettext("ui", "执行记录")}
        </.button>
        <.button
          :if={@can_cancel}
          id={"#{@id}-cancel"}
          size="xs"
          variant="ghost"
          icon="lucide-square"
          phx-click="ask_cancel_run"
          phx-value-id={@run.id}
        >
          {dgettext("ui", "停止")}
        </.button>
        <.button
          :if={@can_retry}
          id={"#{@id}-retry"}
          size="xs"
          variant="ghost"
          icon="lucide-rotate-ccw"
          phx-click="retry_run"
          phx-value-id={@run.id}
        >
          {dgettext("ui", "重试")}
        </.button>
      </div>
    </article>
    """
  end

  @doc "Whether 停止 shows for `run` (status and permission, D8)."
  def cancellable?(scope, run),
    do:
      run.status in ~w(queued deferred claimed running) and
        HelmsmanWeb.RunData.can?(scope, :cancel, run)

  @doc "Whether 重试 shows for `run`."
  def retryable?(scope, run),
    do:
      run.status in ~w(failed cancelled) and run[:retry_run_id] == nil and
        HelmsmanWeb.RunData.can?(scope, :retry, run)
end
