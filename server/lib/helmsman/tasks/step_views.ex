defmodule Helmsman.Tasks.StepViews do
  @moduledoc """
  What each step of an epic waits for, as `get_task` shows it
  (`improve-squad-leader-orchestration` decision 13; task-epics 「Epic 的
  读取」): `waiting_for` and `blocked_by` (`Helmsman.Tasks.Epics.step_states/2`),
  and `orchestrable` — for a run token, whether the step is an
  orchestration target of the run (in its scope and not its root,
  `Helmsman.Squads.Orchestration`); nil for other callers.
  """

  alias Helmsman.Accounts.Scope
  alias Helmsman.Runs.Run
  alias Helmsman.Squads.Orchestration
  alias Helmsman.Tasks.{Epics, Task}

  @type view :: %{
          waiting_for: Epics.waiting(),
          blocked_by: [String.t()],
          orchestrable: boolean() | nil
        }

  @doc "`%{step_ident => view}` for the epic `epic`, read for `scope`; empty for a task."
  @spec for_epic(Scope.t(), Task.t()) :: %{String.t() => view()}
  def for_epic(%Scope{} = scope, %Task{kind: :epic} = epic) do
    targets = targets(scope)

    epic
    |> Epics.step_states()
    |> Map.new(fn state ->
      {state.task.ident,
       %{
         waiting_for: state.waiting_for,
         blocked_by: state.blocked_by,
         orchestrable: targets && state.task.id in targets
       }}
    end)
  end

  def for_epic(%Scope{}, %Task{}), do: %{}

  # The orchestration targets of a run token (none without a root); nil
  # for other callers.
  defp targets(%Scope{via: :run, run: %Run{squad_id: squad_id, task: task}}) do
    case Orchestration.root(task, squad_id) do
      nil ->
        []

      root ->
        root |> Orchestration.scope_ids(squad_id) |> MapSet.to_list() |> List.delete(root.id)
    end
  end

  defp targets(_scope), do: nil
end
