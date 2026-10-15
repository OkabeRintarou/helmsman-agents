defmodule HelmsmanWeb.SpecErrors do
  @moduledoc """
  The texts of the task-spec errors and dispatch results on the spec pages
  (add-spec-workflow-ui D14): `message/1` for the domain's reasons (`add-spec-workflow`
  decision 20), `dispatch_text/1` for the run a write started or woke.
  """
  use Gettext, backend: HelmsmanWeb.Gettext

  require Logger

  alias HelmsmanWeb.RunComponents

  @doc "The message of a domain error reason."
  def message({:spec, :stale_version, latest}),
    do: dgettext("ui", "最新已是 v%{n}", n: latest)

  def message({:spec, :closed, :finalized}), do: dgettext("ui", "规格已定稿")
  def message({:spec, :closed, :abandoned}), do: dgettext("ui", "规格已放弃")
  def message({:spec, :closed, _status}), do: dgettext("ui", "规格已关闭")
  def message({:spec, :not_closed, _status}), do: dgettext("ui", "规格没有定稿或放弃，不需要重新打开")
  def message({:spec, :no_changes}), do: dgettext("ui", "没有可提交的修改")
  def message({:spec, :no_version}), do: dgettext("ui", "规格还没有版本")
  def message({:spec, :no_proposal}), do: dgettext("ui", "没有待批准的提议")
  def message({:spec, :pending_approval}), do: dgettext("ui", "规格待批准，不能请求评审")
  def message({:spec, :not_found, _ident}), do: dgettext("ui", "这个任务还没有规格")
  def message({:spec, :version_not_found, n}), do: dgettext("ui", "没有 v%{n}", n: n)

  def message({:spec, :invalid, errors}) do
    shown = errors |> Enum.take(10) |> Enum.map_join("；", &validation_line/1)
    dgettext("ui", "校验未通过：%{errors}", errors: shown)
  end

  def message({:spec, :unresolved_issues, refs}),
    do: dgettext("ui", "还有未解决的 P1 / P2 问题：%{refs}", refs: Enum.join(refs, "、"))

  def message({:spec, :reviews_pending, names}),
    do: dgettext("ui", "最新版本还有待完成的评审：%{names}", names: Enum.join(names, "、"))

  def message({:spec, :own_version, name}),
    do: dgettext("ui", "%{name} 写了这个版本，不能评审它", name: name)

  def message({:spec, :issue_resolved, ref, resolution}),
    do:
      dgettext("ui", "%{ref} 已是%{state}，可以追加评论",
        ref: ref,
        state: resolution_label(resolution)
      )

  def message({:spec, :issue_not_found, ref}), do: dgettext("ui", "没有问题 %{ref}", ref: ref)

  def message({:spec, :not_coordinator, _who}),
    do: dgettext("ui", "只有协调者（小队 leader 或执行方 Agent）或人可以这样做")

  def message({:spec, :invalid_reviewer, name}),
    do: dgettext("ui", "%{name} 不能评审规格（只能请人、托管 Agent 或外接 Agent）", name: name)

  def message({:spec, :review_pending, %{reviewer: reviewer, request: n}}),
    do: dgettext("ui", "%{name} 已在评审 R%{n}", name: reviewer, n: n)

  def message({:spec, :invalid_files, problems}),
    do:
      dgettext("ui", "文件不合法：%{list}",
        list: Enum.map_join(problems, "；", &"#{&1.path} #{&1.message}")
      )

  def message({:spec, :invalid_issues, problems}),
    do:
      dgettext("ui", "问题不合法：%{list}",
        list: Enum.map_join(problems, "；", &"##{&1.index} #{&1.message}")
      )

  def message({:spec, :invalid_params, %{field: field, message: text}}),
    do: dgettext("ui", "参数 %{field} 不合法：%{message}", field: field, message: text)

  def message({:spec, :invalid_archive, _detail}),
    do: dgettext("ui", "压缩包不合法：含链接、绝对路径或 ..，或不是 tar.gz / zip")

  def message(%Ecto.Changeset{} = changeset) do
    case changeset.errors[:change_id] do
      {"has already been taken", _} -> dgettext("ui", "这个 change_id 已被使用")
      {_text, _} -> dgettext("ui", "change_id 只能用 2–64 个小写字母、数字与 -，以字母或数字开头")
      nil -> dgettext("ui", "参数不合法")
    end
  end

  def message(:forbidden), do: dgettext("ui", "你没有权限执行这个操作")
  def message(:not_found), do: dgettext("ui", "任务不存在")
  def message(:busy), do: dgettext("ui", "有并发修改，请重试")
  def message(:unavailable), do: dgettext("ui", "规格功能暂不可用")

  def message(reason) do
    Logger.warning("unknown spec error: #{inspect(reason)}")
    inspect(reason)
  end

  @doc "「文件:行 规则 说明」of one validation error."
  def validation_line(%{file: file, line: line, rule: rule, message: text}) do
    location = if line, do: "#{file}:#{line}", else: file || ""
    name = rule_label(rule)
    "#{location} #{name}#{if name != rule, do: "（#{text}）", else: " #{text}"}"
  end

  @doc "The Chinese name of a validation rule; unknown rules as given."
  def rule_label("no_deltas"), do: dgettext("ui", "没有增量")
  def rule_label("no_delta_sections"), do: dgettext("ui", "文件里没有增量小节")
  def rule_label("requirement_text_missing"), do: dgettext("ui", "需求缺少正文")
  def rule_label("requirement_no_normative"), do: dgettext("ui", "需求正文没有 SHALL / MUST")
  def rule_label("requirement_no_scenario"), do: dgettext("ui", "需求没有场景")
  def rule_label("duplicate_requirement"), do: dgettext("ui", "需求重名")
  def rule_label("requirement_conflict"), do: dgettext("ui", "需求在多个小节冲突")
  def rule_label("renamed_malformed"), do: dgettext("ui", "RENAMED 格式不对")
  def rule_label("missing_proposal"), do: dgettext("ui", "缺少 proposal.md")
  def rule_label("missing_tasks"), do: dgettext("ui", "缺少 tasks.md")

  def rule_label("proposal_sections"),
    do: dgettext("ui", "proposal.md 缺少 ## Why 或 ## What Changes")

  def rule_label("tasks_no_items"), do: dgettext("ui", "tasks.md 没有勾选项")
  def rule_label(rule), do: rule

  @doc "The name of an issue's resolution."
  def resolution_label(r) when is_binary(r), do: resolution_label(String.to_existing_atom(r))
  def resolution_label(:open), do: dgettext("ui", "待回复")
  def resolution_label(:accepted), do: dgettext("ui", "已接受")
  def resolution_label(:disputed), do: dgettext("ui", "有异议")
  def resolution_label(:withdrawn), do: dgettext("ui", "已撤回")
  def resolution_label(:upheld), do: dgettext("ui", "维持")
  def resolution_label(:dismissed), do: dgettext("ui", "驳回")
  def resolution_label(other), do: to_string(other)

  @doc """
  `{:info | :warning, text}` for the run a review request started (`request` of
  `request_reviews/4`'s result).
  """
  def request_text(%{reviewer: name, existing: true, request: n}),
    do: {:info, dgettext("ui", "%{name} 已在评审 R%{n}，未重复请求", name: name, n: n)}

  def request_text(%{reviewer: name, dispatch: nil}),
    do: {:info, dgettext("ui", "已请 %{name} 评审", name: name)}

  def request_text(%{reviewer: name, dispatch: %{result: result} = d}) do
    case to_atom(result) do
      :queued ->
        {:info, dgettext("ui", "已为 %{name} 排队评审", name: name)}

      :skipped ->
        {_level, text} = RunComponents.dispatch_message(outcome(d))
        {:warning, dgettext("ui", "%{text}（请求已建立）", text: text)}

      _other ->
        RunComponents.dispatch_message(outcome(d))
    end
  end

  @doc """
  `{level, text}` for a coordinator woken by a review, a decision or a rejection; nil
  without a dispatch.
  """
  def wake_text(nil), do: nil
  def wake_text(false), do: nil

  def wake_text(%{result: result, target: target, squad: squad} = d) do
    case to_atom(result) do
      r when r in [:queued, :merged, :deferred] and is_binary(squad) ->
        {:info, dgettext("ui", "已唤醒 %{squad} 的 leader（%{leader}）", squad: squad, leader: target)}

      r when r in [:queued, :merged, :deferred] ->
        {:info, dgettext("ui", "已唤醒 %{agent}", agent: target)}

      :skipped ->
        reason = RunComponents.skip_reason(target, d.reason)

        text =
          if reason,
            do: dgettext("ui", "没有唤醒 %{agent}：%{reason}", agent: squad || target, reason: reason),
            else: dgettext("ui", "没有唤醒 %{agent}", agent: squad || target)

        {:warning, text}

      _other ->
        RunComponents.dispatch_message(outcome(d))
    end
  end

  defp outcome(d),
    do: %{agent: d.target, squad: d[:squad], result: d.result, reason: d[:reason]}

  defp to_atom(v) when is_atom(v), do: v
  defp to_atom(v) when is_binary(v), do: String.to_existing_atom(v)
end
