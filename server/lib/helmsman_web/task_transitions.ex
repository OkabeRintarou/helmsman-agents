defmodule HelmsmanWeb.TaskTransitions do
  @moduledoc """
  Transition buttons of the task page (design D7, spec web-task-transitions). Pure
  functions: which transitions exist comes from `Helmsman.Tasks.StateMachine.allowed/1`,
  this module only names them and picks how they are entered.

    * `:direct` — runs at once (开始, 恢复);
    * `:evidence` — 完成 / 验收 open the evidence panel;
    * `:reason` — the other transitions open a panel asking for a reason.

  Secondary buttons come first in a fixed order, the primary one last.
  """
  use Gettext, backend: HelmsmanWeb.Gettext

  require Logger

  alias HelmsmanWeb.Components.Status

  @type button :: %{
          to: String.t(),
          label: String.t(),
          kind: :direct | :evidence | :reason,
          primary?: boolean()
        }

  @secondary_order ~w(in_progress rejected cancelled)

  @doc """
  The buttons for a task in `status` given the allowed target statuses.
  Combinations missing from the table are skipped with a warning.
  """
  @spec buttons(String.t(), [atom() | String.t()]) :: [button()]
  def buttons(status, allowed) do
    buttons =
      for to <- Enum.map(allowed, &to_string/1),
          button = button(status, to) || unknown(status, to),
          button != nil,
          do: button

    {primary, secondary} = Enum.split_with(buttons, & &1.primary?)
    Enum.sort_by(secondary, &secondary_rank/1) ++ primary
  end

  defp secondary_rank(%{to: to, label: label}),
    do: {Enum.find_index(@secondary_order, &(&1 == to)) || 99, label}

  defp unknown(from, to) do
    Logger.warning("TaskTransitions: no button for transition #{from} -> #{to}")
    nil
  end

  defp button("new", "in_progress"), do: b("in_progress", dgettext("ui", "开始"), :direct, true)
  defp button("in_progress", "done"), do: b("done", dgettext("ui", "完成"), :evidence, true)
  defp button("done", "verified"), do: b("verified", dgettext("ui", "验收"), :evidence, true)
  defp button("done", "in_progress"), do: b("in_progress", dgettext("ui", "打回"), :reason, false)

  defp button("verified", "in_progress"),
    do: b("in_progress", dgettext("ui", "重开"), :reason, false)

  defp button(from, "rejected") when from in ~w(new in_progress),
    do: b("rejected", dgettext("ui", "拒绝"), :reason, false)

  defp button("rejected", "new"), do: b("new", dgettext("ui", "重新提交"), :reason, true)

  defp button(from, "cancelled") when from in ~w(new in_progress),
    do: b("cancelled", dgettext("ui", "撤销"), :reason, false)

  defp button("cancelled", "new"), do: b("new", dgettext("ui", "恢复"), :direct, true)
  defp button(_from, _to), do: nil

  defp b(to, label, kind, primary?), do: %{to: to, label: label, kind: kind, primary?: primary?}

  @doc """
  Name of the direct transition to `to` (开始 / 恢复). Used for errors of a direct
  transition, whose `from` may already have changed on the page.
  """
  @spec direct_label(String.t()) :: String.t()
  def direct_label("in_progress"), do: dgettext("ui", "开始")
  def direct_label("new"), do: dgettext("ui", "恢复")
  def direct_label(to), do: Status.task_status(to).label

  @doc """
  Kind of the reason feedback of a transition to `to` (designs/09 §3): a comment for
  撤销, a review for 打回, 重开, 拒绝 and 重新提交.

      iex> HelmsmanWeb.TaskTransitions.reason_kind("cancelled")
      "comment"
      iex> HelmsmanWeb.TaskTransitions.reason_kind("in_progress")
      "review"
  """
  @spec reason_kind(String.t()) :: String.t()
  def reason_kind("cancelled"), do: "comment"
  def reason_kind(_to), do: "review"

  @doc "Explanation shown in the reason panel of `from → to`."
  @spec panel_help(String.t(), String.t()) :: String.t()
  def panel_help("done", "in_progress"),
    do: dgettext("ui", "任务回到「进行中」，执行方不变。原因会记入历史，供执行方参考。")

  def panel_help("verified", "in_progress"),
    do: dgettext("ui", "已验收的任务重新回到「进行中」。原因会记入历史。")

  def panel_help(_from, "rejected"),
    do: dgettext("ui", "拒绝后任务结束；之后可以修改并重新提交。原因会记入历史。")

  def panel_help("rejected", "new"),
    do: dgettext("ui", "任务回到「新建」，可以重新开始。请说明做了哪些修改。")

  def panel_help(_from, "cancelled"),
    do: dgettext("ui", "撤销后任务结束；之后可以恢复。原因会记入历史。")

  def panel_help(_from, _to), do: ""

  @doc """
  The self-verification hint of the 验收 panel: `nil` unless the acting identity is the
  task's assignee (an agent's owner is not its assignee). `last_done_tests` are the
  tests of the latest transition to `done` (or nil). Only a hint — the domain decides.
  """
  @spec self_verify_hint(map(), map()) :: nil | %{last_done_tests: map() | nil}
  def self_verify_hint(%{assignee: %{name: name}} = task, %{actor: %{name: name}}) do
    last_done =
      task
      |> Map.get(:history, [])
      |> Enum.filter(&(&1.to == "done"))
      |> List.last()

    %{last_done_tests: last_done && Map.get(last_done, :tests)}
  end

  def self_verify_hint(_task, _scope), do: nil
end
