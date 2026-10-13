defmodule HelmsmanWeb.TaskLive.TransitionErrors do
  @moduledoc """
  Display text for the errors of `Helmsman.Tasks.transition/4` (design D8).

  Returns `{where, text}`:

    * `:blocked` — the task moved on (`status_changed`, `invalid_transition`): shown at the top of the
      panel with the submit button disabled, or as an error flash for direct
      transitions;
    * `{:field, field}` — under a panel field (`:commits`, `:tests`, `:comment`);
    * `:top` — at the top of the panel, or as an error flash.

  Status names come from `HelmsmanWeb.Components.Status.task_status/1`.
  """
  use Gettext, backend: HelmsmanWeb.Gettext

  require Logger

  alias HelmsmanWeb.Components.Status
  alias HelmsmanWeb.FormErrors

  @spec message(term(), String.t()) :: {:blocked | :top | {:field, atom()}, String.t()}
  def message({:invalid_transition, from, _to, _allowed}, label) do
    {:blocked,
     dgettext("ui", "任务状态已变为%{status}，无法%{action}",
       status: Status.task_status(from).label,
       action: label
     )}
  end

  # `expected_from` no longer matched (design D12): same text as invalid_transition.
  def message({:status_changed, current}, label),
    do: message({:invalid_transition, current, nil, []}, label)

  def message({:invalid_commits, bad}, _label) do
    bad = bad |> List.wrap() |> Enum.map_join("、", &format/1)
    {{:field, :commits}, dgettext("ui", "不是有效的提交 hash：%{commits}", commits: bad)}
  end

  def message({:invalid_tests, _detail}, _label),
    do: {{:field, :tests}, dgettext("ui", "测试结果无效")}

  def message({:invalid_comment, :too_long}, _label),
    do: {{:field, :comment}, dgettext("ui", "不能超过 10000 个字符")}

  def message({:invalid_comment, _detail}, _label),
    do: {{:field, :comment}, dgettext("ui", "备注无效")}

  def message({:self_verify_requires_tests, _assignee}, _label),
    do: {:top, dgettext("ui", "你是执行方，验收需要通过的测试结果")}

  def message(:forbidden, _label), do: {:top, dgettext("ui", "没有权限执行此操作")}

  # The reason feedback is invalid (too long, …): shown under the reason.
  def message(%Ecto.Changeset{} = changeset, _label) do
    messages = FormErrors.messages(changeset)

    text =
      FormErrors.first(messages, :content) || messages |> Map.values() |> List.flatten() |> hd()

    {{:field, :comment}, text}
  end

  # add-collaboration-ui D3: refused because of links.
  def message({:blocked, ids}, _label) when is_list(ids),
    do: {:top, dgettext("ui", "被 %{tasks} 阻塞（前置任务还没满足），不能开始", tasks: Enum.join(ids, "、"))}

  def message({:replaced, ids}, _label) when is_list(ids),
    do: {:top, HelmsmanWeb.CollabComponents.replaced_text(ids)}

  # A run is still working on the task (web-runs 运行进行中时的验收).
  def message({:run_active, %{agent: agent}}, _label),
    do: {:top, run_active_text(agent)}

  # Only a programming error sends a reason that is not a map.
  def message({:invalid_feedback, _detail} = reason, label) do
    Logger.error("Task transition #{label} failed: #{inspect(reason)}")
    {:top, dgettext("ui", "操作失败，请稍后重试")}
  end

  def message(reason, label) do
    Logger.error("Task transition #{label} failed: #{inspect(reason)}")
    {:top, dgettext("ui", "操作失败，请稍后重试")}
  end

  @doc "Why 验收 waits while `agent` is running on the task."
  @spec run_active_text(String.t()) :: String.t()
  def run_active_text(agent),
    do: dgettext("ui", "%{agent} 正在运行，等它结束后再验收", agent: agent)

  defp format(value) when is_binary(value), do: value
  defp format(value), do: inspect(value)
end
