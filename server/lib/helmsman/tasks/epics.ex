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

  require Helmsman.Links
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

  @active_runs ["queued", "claimed", "running", "cancelling"]

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

  @typedoc "What a step waits for (`step_states/2`); nil: nothing."
  @type waiting ::
          :merge
          | :verification
          | :requester
          | :answer
          | :run
          | :prerequisites
          | :assignment
          | :assignee
          | :start
          | nil

  @type step_state :: %{
          task: Task.t(),
          waiting_for: waiting(),
          blocked_by: [String.t()],
          assignee_kind: :human | :agent | :external | :squad | nil,
          latest_run_id: pos_integer() | nil,
          active_run: boolean(),
          deferred_run: boolean()
        }

  @doc """
  The state of each step of `epic`, in creation order
  (`improve-squad-leader-orchestration` decision 13; task-epics 「Epic 的
  读取」): `waiting_for`, the first that holds of — nothing (`verified`
  and satisfied, or `cancelled`); `:merge` (verified, not satisfied);
  `:verification` (done); `:requester` (rejected); `:answer` (an open
  question); `:run` (a queued, claimed, running or cancelling run);
  `:prerequisites` (a deferred run); `:assignment` (no assignee); for a
  person or an external agent assignee `:prerequisites` (an unsatisfied
  prerequisite) or `:assignee`; else (a managed agent or a squad without
  any run, whether or not its prerequisites hold) `:start`. Also the
  unsatisfied prerequisites (`blocked_by`), the assignee's kind, the
  latest run and whether a run is active or deferred.

  Three queries whatever the number of steps. Options: `exclude_run_id`,
  a run left out (the claim check of `epic_stalled`).
  """
  @spec step_states(Task.t(), keyword()) :: [step_state()]
  def step_states(%Task{} = epic, opts \\ []) do
    from(t in Task,
      where: t.workspace_id == ^epic.workspace_id and t.epic_id == ^epic.id,
      order_by: [asc: t.inserted_at, asc: t.id]
    )
    |> states(opts)
  end

  @doc """
  The same states as `step_states/2` for any tasks (`task_ids`, in that
  order; unknown IDs left out): the tasks of an orchestration scope that
  are not an epic's steps. Three queries.
  """
  @spec task_states([pos_integer()], keyword()) :: [step_state()]
  def task_states(task_ids, opts \\ [])
  def task_states([], _opts), do: []

  def task_states(task_ids, opts) when is_list(task_ids) do
    order = task_ids |> Enum.with_index() |> Map.new()

    from(t in Task, where: t.id in ^task_ids)
    |> states(opts)
    |> Enum.sort_by(&Map.fetch!(order, &1.task.id))
  end

  defp states(query, opts) do
    steps = rows(query)
    ids = Enum.map(steps, fn {task, _kind, _waiting} -> task.id end)
    runs = run_facts(ids, opts[:exclude_run_id])
    blockers = Links.blockers_of(ids)

    Enum.map(steps, fn {task, kind, satisfaction} ->
      facts = Map.get(runs, task.id, %{active: false, deferred: false, latest: nil})
      blocked_by = Map.get(blockers, task.id, [])

      %{
        task: task,
        waiting_for: waiting(task, kind, satisfaction, facts, blocked_by),
        blocked_by: blocked_by,
        assignee_kind: kind,
        latest_run_id: facts.latest,
        active_run: facts.active,
        deferred_run: facts.deferred
      }
    end)
  end

  defp rows(query) do
    from(t in query,
      left_join: a in Helmsman.Actors.Actor,
      on: a.id == t.assignee_id,
      left_join: p in Helmsman.Agents.AgentProfile,
      on: p.actor_id == a.id,
      select:
        {t, a.kind, not is_nil(p.id), Links.waiting_for_sql(t.id, t.project_id, t.status, t.kind)}
    )
    |> Repo.all()
    |> Enum.map(fn {task, kind, profile?, waiting} ->
      {task, assignee_kind(kind, profile?), Links.waiting_for_value(waiting)}
    end)
  end

  defp assignee_kind(nil, _profile?), do: nil
  defp assignee_kind(:agent, false), do: :external
  defp assignee_kind(kind, _profile?), do: kind

  defp run_facts([], _exclude), do: %{}

  defp run_facts(ids, exclude) do
    from(r in Helmsman.Runs.Run,
      where: r.task_id in ^ids and r.id != ^(exclude || 0),
      group_by: r.task_id,
      select:
        {r.task_id, fragment("bool_or(? = ANY(?))", type(r.status, :string), ^@active_runs),
         fragment("bool_or(? = 'deferred')", type(r.status, :string)), max(r.id)}
    )
    |> Repo.all()
    |> Map.new(fn {id, active, deferred, latest} ->
      {id, %{active: active, deferred: deferred, latest: latest}}
    end)
  end

  defp waiting(%Task{status: :cancelled}, _kind, _satisfaction, _facts, _blocked), do: nil
  defp waiting(%Task{status: :verified}, _kind, nil, _facts, _blocked), do: nil
  defp waiting(%Task{status: :verified}, _kind, _waiting, _facts, _blocked), do: :merge
  defp waiting(%Task{status: :done}, _kind, _satisfaction, _facts, _blocked), do: :verification
  defp waiting(%Task{status: :rejected}, _kind, _satisfaction, _facts, _blocked), do: :requester
  defp waiting(%Task{open_question: true}, _kind, _satisfaction, _facts, _blocked), do: :answer
  defp waiting(_task, _kind, _satisfaction, %{active: true}, _blocked), do: :run
  defp waiting(_task, _kind, _satisfaction, %{deferred: true}, _blocked), do: :prerequisites
  defp waiting(_task, nil, _satisfaction, _facts, _blocked), do: :assignment

  defp waiting(_task, kind, _satisfaction, _facts, blocked) when kind in [:human, :external],
    do: if(blocked == [], do: :assignee, else: :prerequisites)

  defp waiting(_task, _kind, _satisfaction, _facts, _blocked), do: :start

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
