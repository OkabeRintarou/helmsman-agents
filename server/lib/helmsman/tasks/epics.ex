defmodule Helmsman.Tasks.Epics do
  @moduledoc """
  Epics and their steps (designs/04 §3, 05 §6; `add-epics`).

  An epic is a task of kind `epic`; tasks of kind `task` may belong to one
  (`epic_id`, same workspace, any project) and are then its steps. Its
  progress is aggregated on read (`progress/2`), never stored.

  `recompute/3` keeps an epic's status in line with its steps. Every
  caller holds the workspace graph lock: step transitions and attaching or
  detaching steps all take it, so the set of steps it reads is stable.
  The automatic transitions it makes are bookkeeping only: they do not run
  `Helmsman.Tasks.TransitionSteps`, start runs or reconcile pull requests
  (decision 6); they only notify the epic's dependents through
  `Helmsman.Links.status_changed/3` (decision 11).
  """

  import Ecto.Query, warn: false

  alias Helmsman.Accounts.Scope
  alias Helmsman.Events
  alias Helmsman.Links
  alias Helmsman.Repo
  alias Helmsman.Tasks
  alias Helmsman.Tasks.{Task, TaskEvent}

  @type progress :: %{
          total: non_neg_integer(),
          done: non_neg_integer(),
          by_status: %{String.t() => non_neg_integer()}
        }
  @type cause :: :step_transition | :step_added | :step_removed
  @type event_attrs :: %{actor_id: pos_integer(), source_run_id: pos_integer() | nil}

  @completed [:done, :verified]
  @finished [:done, :verified, :cancelled]

  @doc """
  The progress of each epic of `epic_ids` in the workspace: step count,
  completed steps (`done` and `verified`) and the count of every status
  (all six keys). One query; none for no IDs.
  """
  @spec progress(pos_integer(), [pos_integer()]) :: %{pos_integer() => progress()}
  def progress(_workspace_id, []), do: %{}

  def progress(workspace_id, epic_ids) when is_list(epic_ids) do
    counts =
      from(t in Task,
        where: t.workspace_id == ^workspace_id and t.epic_id in ^epic_ids,
        group_by: [t.epic_id, t.status],
        select: {t.epic_id, t.status, count()}
      )
      |> Repo.all()
      |> Enum.group_by(&elem(&1, 0), &{elem(&1, 1), elem(&1, 2)})

    Map.new(epic_ids, fn id -> {id, build_progress(Map.get(counts, id, []))} end)
  end

  defp build_progress(counts) do
    counts = Map.new(counts)

    %{
      total: counts |> Map.values() |> Enum.sum(),
      done: @completed |> Enum.map(&Map.get(counts, &1, 0)) |> Enum.sum(),
      by_status: Map.new(Task.statuses(), &{Atom.to_string(&1), Map.get(counts, &1, 0)})
    }
  end

  @doc """
  The `TransitionSteps` step: after a step's transition, recomputes its
  epic as `:step_transition`, in the name of the identity and run of the
  transition's history entry.
  """
  @spec after_transition(Task.t(), TaskEvent.t(), Scope.t()) :: :ok
  def after_transition(%Task{epic_id: nil}, _event, _scope), do: :ok

  def after_transition(%Task{epic_id: epic_id}, %TaskEvent{} = event, _scope) do
    recompute(epic_id, :step_transition, %{
      actor_id: event.actor_id,
      source_run_id: event.source_run_id
    })
  end

  @doc """
  Recomputes the epic `epic_id` after its steps changed (`cause`), inside
  the caller's transaction, which holds the workspace graph lock. Locks
  the epic row `FOR UPDATE`.

  | epic                | steps                                         | to          |
  |---------------------|-----------------------------------------------|-------------|
  | cancelled, rejected | -                                             | unchanged   |
  | new, in_progress    | some, all done / verified / cancelled, one done or verified | done |
  | done, verified      | one new / in_progress / rejected (not on `:step_removed`) | in_progress |

  An automatic transition is an `auto` history entry by
  `event_attrs.actor_id` (and `source_run_id`) and a new status; the
  epic's `lock_version` is unchanged. After the commit the epic's summary
  is broadcast on its project topic and `{:task_updated, ident}` on its
  task topic, plus `{:task_transitioned, %{ident, event}}` for an
  automatic transition, once per transaction for each epic; an automatic
  transition also notifies the tasks depending on the epic
  (`Helmsman.Links.status_changed/3`).
  """
  @spec recompute(pos_integer(), cause(), event_attrs()) :: :ok
  def recompute(epic_id, cause, event_attrs)
      when cause in [:step_transition, :step_added, :step_removed] do
    epic = Repo.one!(from(t in Task, where: t.id == ^epic_id, lock: "FOR UPDATE"))

    statuses =
      Repo.all(
        from(t in Task,
          where: t.workspace_id == ^epic.workspace_id and t.epic_id == ^epic.id,
          distinct: true,
          select: t.status
        )
      )

    case decide(epic.status, statuses, cause) do
      nil ->
        notify(epic, nil)

      {to, comment} ->
        event =
          Repo.insert!(%TaskEvent{
            workspace_id: epic.workspace_id,
            task_id: epic.id,
            from_status: epic.status,
            to_status: to,
            actor_id: event_attrs.actor_id,
            comment: comment,
            commits: [],
            auto: true,
            source_run_id: event_attrs[:source_run_id]
          })

        from = epic.status
        epic = epic |> Ecto.Changeset.change(status: to) |> Repo.update!()
        :ok = Links.status_changed(epic, from, to)
        notify(epic, event)
    end
  end

  @doc false
  # The decision table of `recompute/3`, on the distinct step statuses.
  @spec decide(Task.status(), [Task.status()], cause()) :: {Task.status(), String.t()} | nil
  def decide(epic_status, statuses, cause)

  def decide(status, statuses, _cause) when status in [:new, :in_progress] do
    if statuses != [] and Enum.all?(statuses, &(&1 in @finished)) and
         Enum.any?(statuses, &(&1 in @completed)),
       do: {:done, "all steps completed (auto)"}
  end

  def decide(status, statuses, cause)
      when status in [:done, :verified] and cause != :step_removed do
    if Enum.any?(statuses, &(&1 not in @finished)), do: {:in_progress, reopen_comment(cause)}
  end

  def decide(_status, _statuses, _cause), do: nil

  defp reopen_comment(:step_transition), do: "step reopened (auto)"
  defp reopen_comment(:step_added), do: "step added (auto)"

  defp notify(%Task{} = epic, event) do
    summary = epic |> Tasks.load_summary() |> Tasks.summary()
    key = {:epic, epic.id}

    Events.after_commit_once(
      key,
      Events.topic(:project, epic.project_id),
      {:task_updated, summary}
    )

    Events.after_commit_once(key, Events.topic(:task, epic.id), {:task_updated, epic.ident})

    if event do
      event = %{Repo.preload(event, :actor) | feedback_ident: nil}

      Events.after_commit_once(
        {:epic_transitioned, epic.id},
        Events.topic(:task, epic.id),
        {:task_transitioned, %{ident: epic.ident, event: Tasks.event_view(event)}}
      )
    end

    :ok
  end
end
