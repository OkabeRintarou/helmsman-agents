defmodule Helmsman.Squads.EpicWatch do
  @moduledoc """
  The stall watchdog of epics led by squads
  (`improve-squad-leader-orchestration` decisions 9–12).

  An epic E is stalled (`stalled?/1`) when its assignee is an enabled
  squad, E is `in_progress` with no open question and no unsatisfied
  prerequisite, nothing runs on E or its steps (queued, claimed, running
  or cancelling), and at least one step is idle: it waits for
  `:assignment` or `:start` (`Helmsman.Tasks.Epics.step_states/2`). A
  deferred run only keeps its own step from being idle.

  Checks run in `Helmsman.Squads.Workers.EpicWatch` jobs (`schedule/2`),
  inserted — never with a task lock — when a run on E or a step ends, E
  or a step changes status, a person writes on E or a step, and by the
  dependency sweep (`sweep/0`, the oldest checks first; `epic_watch_checks`
  records every check). `check/1` locks the squad's rows, then E's row,
  decides, and either wakes the current leader as the squad with an
  `epic_stalled` trigger (inheriting E's `assign` grant of the squad),
  skips, or notes that it stopped waking (capped).

  Within a progress cycle — since the latest step done / verified /
  cancelled, or a person's transition or feedback on E or a step — a
  signature (E's status and the idle steps with their status, assignee and
  latest run) equal to the cycle's latest `epic_stalled` trigger wakes
  nobody (`same_signature`), and `max_consecutive` triggers in the cycle
  cap it (`capped`, one note per cycle). Across cycles, wakes are at least
  `min_interval_minutes` apart (`too_soon`, checked again then).
  """

  import Ecto.Query, warn: false

  require Logger

  alias Helmsman.Accounts.Scope
  alias Helmsman.Actors.Actor
  alias Helmsman.{Feedback, Links, Locks, Repo}
  alias Helmsman.Feedback.Entry
  alias Helmsman.Runs.{Origin, Outcome, Run, TaskGrant}
  alias Helmsman.Squads.Dispatch, as: SquadDispatch
  alias Helmsman.Squads.EpicWatchCheck
  alias Helmsman.Squads.Workers.EpicWatch, as: Job
  alias Helmsman.Tasks.{Epics, Task, TaskEvent}

  @active ["queued", "claimed", "running", "cancelling"]
  @max_listed 20
  @defaults [grace_seconds: 120, min_interval_minutes: 15, max_consecutive: 3, sweep_batch: 200]

  @type result ::
          :woken | :not_stalled | :same_signature | :too_soon | :capped | :no_grant | :skipped

  @doc "The configuration: `grace_seconds`, `min_interval_minutes`, `max_consecutive`, `sweep_batch`."
  @spec config(atom()) :: non_neg_integer()
  def config(key),
    do:
      Keyword.fetch!(
        Keyword.merge(@defaults, Application.get_env(:helmsman, __MODULE__, [])),
        key
      )

  ## The stall (decision 9)

  @typedoc "What `stalled?/1` decides on, read by `snapshot/2`."
  @type snapshot :: %{
          epic: Task.t(),
          squad_enabled: boolean(),
          blocked: boolean(),
          epic_active: boolean(),
          steps: [Epics.step_state()]
        }

  @doc """
  Reads what decides whether `epic` is stalled (its steps' states and one
  more query). Options: `exclude_run_id` (a run left out: the claim check
  of the `epic_stalled` run itself).
  """
  @spec snapshot(Task.t(), keyword()) :: snapshot()
  def snapshot(%Task{} = epic, opts \\ []) do
    exclude = opts[:exclude_run_id] || 0

    facts =
      from(t in Task,
        as: :task,
        left_join: a in Actor,
        on: a.id == t.assignee_id and a.kind == :squad,
        where: t.id == ^epic.id,
        select: %{
          squad_enabled: not is_nil(a.id) and is_nil(a.disabled_at),
          epic_active:
            exists(
              from(r in Run,
                where:
                  r.task_id == parent_as(:task).id and r.id != ^exclude and
                    type(r.status, :string) in ^@active,
                select: 1
              )
            )
        }
      )
      |> select_merge(^%{blocked: Links.unsatisfied_dependency(:task)})
      |> Repo.one!()

    {squad_enabled, blocked, epic_active} =
      {facts.squad_enabled, facts.blocked, facts.epic_active}

    %{
      epic: epic,
      squad_enabled: squad_enabled,
      blocked: blocked,
      epic_active: epic_active,
      steps: Epics.step_states(epic, exclude_run_id: opts[:exclude_run_id])
    }
  end

  @doc "Whether the snapshot is a stall; see the module documentation. Pure."
  @spec stalled?(snapshot()) :: boolean()
  def stalled?(%{epic: epic} = snapshot) do
    snapshot.squad_enabled and epic.status == :in_progress and not epic.open_question and
      not snapshot.blocked and not snapshot.epic_active and
      not Enum.any?(snapshot.steps, & &1.active_run) and idle(snapshot) != []
  end

  @doc "The idle steps of a snapshot: those waiting for `:assignment` or `:start`."
  @spec idle(snapshot()) :: [Epics.step_state()]
  def idle(snapshot), do: Enum.filter(snapshot.steps, &(&1.waiting_for in [:assignment, :start]))

  @doc """
  The stall signature: SHA-256 (hex) of E's status and the idle steps
  `[id, status, assignee_id, latest run id]` in ID order.
  """
  @spec signature(snapshot()) :: String.t()
  def signature(snapshot) do
    steps =
      snapshot
      |> idle()
      |> Enum.map(
        &[&1.task.id, Atom.to_string(&1.task.status), &1.task.assignee_id, &1.latest_run_id]
      )
      |> Enum.sort()

    [Atom.to_string(snapshot.epic.status), steps]
    |> Jason.encode!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  ## Scheduling (decision 11)

  @doc """
  Inserts a check of each epic among `task_ids` (an epic, or the epic of a
  step) assigned to a squad, `in` seconds from now (default the grace
  time); a check already waiting is moved to that time. Reads without
  locks; inserts jobs only.
  """
  @spec schedule([pos_integer()], non_neg_integer() | nil) :: :ok
  def schedule(task_ids, delay \\ nil)
  def schedule([], _delay), do: :ok

  def schedule(task_ids, delay) do
    delay = delay || config(:grace_seconds)

    from(t in Task,
      join: e in Task,
      on: e.id == fragment("CASE WHEN ? = 'epic' THEN ? ELSE ? END", t.kind, t.id, t.epic_id),
      join: a in Actor,
      on: a.id == e.assignee_id and a.kind == :squad,
      where: t.id in ^Enum.uniq(task_ids),
      distinct: true,
      select: e.id
    )
    |> Repo.all()
    |> Enum.each(&insert(&1, DateTime.add(DateTime.utc_now(), delay, :second)))
  end

  defp insert(epic_id, at) do
    {:ok, _job} = Oban.insert(Job.new(%{epic_id: epic_id}, scheduled_at: at))
    :ok
  end

  @doc "The runs that ended: a check of their tasks' epics (`Helmsman.Runs.after_ended/1`)."
  @spec after_runs_ended([Run.t()]) :: :ok
  def after_runs_ended(runs),
    do: runs |> Enum.map(& &1.task_id) |> Enum.reject(&is_nil/1) |> schedule()

  @doc "The `Helmsman.Tasks.TransitionSteps` step: a check of the task's epic."
  @spec after_transition(Task.t(), TaskEvent.t(), Scope.t()) :: :ok
  def after_transition(%Task{id: id}, _event, _scope), do: schedule([id])

  @doc "A person wrote or revised feedback on `task`: a check of its epic (a new cycle)."
  @spec after_feedback(Task.t(), Actor.t()) :: :ok
  def after_feedback(%Task{id: id}, %Actor{kind: :human}), do: schedule([id])
  def after_feedback(_task, _author), do: :ok

  @doc """
  The sweep (`Helmsman.Dispatch.Workers.DependencySweep`): checks, now, at
  most `sweep_batch` epics that may be stalled — assigned to a squad,
  `in_progress`, nothing running on them or their steps, a `new` or
  `in_progress` step without a pending or active run — oldest check
  first, never checked first. Returns how many.
  """
  @spec sweep() :: non_neg_integer()
  def sweep do
    ids = Repo.all(sweep_candidates(config(:sweep_batch)))
    now = DateTime.utc_now()
    Enum.each(ids, &insert(&1, now))
    length(ids)
  end

  defp sweep_candidates(limit) do
    from(e in Task,
      as: :epic,
      join: a in Actor,
      on: a.id == e.assignee_id and a.kind == :squad and is_nil(a.disabled_at),
      left_join: c in EpicWatchCheck,
      on: c.epic_id == e.id,
      where: e.kind == :epic and e.status == :in_progress,
      where: exists(idle_step()) and not exists(busy_step()) and not exists(epic_run()),
      order_by: [asc_nulls_first: c.checked_at, asc: e.id],
      limit: ^limit,
      select: e.id
    )
  end

  # A `new` or `in_progress` step without a pending or active run.
  defp idle_step do
    step_run =
      from(r in Run,
        where:
          r.task_id == parent_as(:step).id and type(r.status, :string) in ^["deferred" | @active],
        select: 1
      )

    from(s in Task,
      as: :step,
      where:
        s.epic_id == parent_as(:epic).id and s.status in [:new, :in_progress] and
          not exists(step_run),
      select: 1
    )
  end

  defp busy_step do
    from(s in Task,
      join: r in Run,
      on: r.task_id == s.id,
      where: s.epic_id == parent_as(:epic).id and type(r.status, :string) in ^@active,
      select: 1
    )
  end

  defp epic_run do
    from(r in Run,
      where: r.task_id == parent_as(:epic).id and type(r.status, :string) in ^@active,
      select: 1
    )
  end

  ## The check (decisions 10–12)

  @doc """
  Checks the epic `epic_id` and acts on it; see the module documentation.
  Its own transaction: maintenance lock (shared), the squad's rows, E's row
  `FOR UPDATE`, then the reads, the decision, the trigger or note, and
  `epic_watch_checks`. Returns the result.
  """
  @spec check(pos_integer()) :: result()
  def check(epic_id) do
    result =
      case Repo.one(
             from(t in Task, where: t.id == ^epic_id, select: {t.workspace_id, t.assignee_id})
           ) do
        nil -> :skipped
        {workspace_id, assignee_id} -> locked_check(epic_id, workspace_id, assignee_id)
      end

    :telemetry.execute([:helmsman, :epic_watch, :check], %{count: 1}, %{result: result})
    result
  end

  defp locked_check(epic_id, workspace_id, guessed_assignee) do
    {:ok, result} =
      Helmsman.Tx.run(
        fn ->
          Locks.maint_shared!(workspace_id)
          loaded = guessed_assignee && lock_squad(guessed_assignee)
          epic = Repo.one!(from(t in Task, where: t.id == ^epic_id, lock: "FOR UPDATE"))

          result =
            if loaded && loaded.actor.id == epic.assignee_id,
              do: decide(epic, loaded),
              else: :not_stalled

          record!(epic, result)
          {:ok, result}
        end,
        retry: 1
      )

    result
  end

  defp lock_squad(actor_id) do
    case SquadDispatch.lock_rows(actor_id) do
      {:ok, loaded} -> loaded
      _not_a_squad_or_busy -> nil
    end
  end

  defp record!(epic, result) do
    Repo.insert_all(
      EpicWatchCheck,
      [
        %{
          workspace_id: epic.workspace_id,
          epic_id: epic.id,
          checked_at: DateTime.utc_now(),
          result: Atom.to_string(result)
        }
      ],
      on_conflict: {:replace, [:checked_at, :result]},
      conflict_target: [:epic_id]
    )
  end

  defp decide(epic, loaded) do
    snapshot = snapshot(epic)

    if stalled?(snapshot),
      do: decide_stalled(epic, loaded, snapshot),
      else: :not_stalled
  end

  defp decide_stalled(epic, loaded, snapshot) do
    marker = progress_marker(epic)
    triggers = stall_triggers(epic)
    in_cycle = Enum.filter(triggers, &after?(&1.at, marker))
    max = config(:max_consecutive)
    signature = signature(snapshot)
    last = List.last(triggers)
    interval = config(:min_interval_minutes) * 60

    cond do
      length(in_cycle) >= max ->
        if max > 0, do: cap_note(epic, loaded, snapshot, marker)
        :capped

      in_cycle != [] and List.last(in_cycle).signature == signature ->
        :same_signature

      last && DateTime.diff(DateTime.utc_now(), last.at) < interval ->
        insert(epic.id, DateTime.add(last.at, interval, :second))
        :too_soon

      true ->
        wake(epic, loaded, snapshot, signature)
    end
  end

  defp after?(_at, nil), do: true
  defp after?(at, marker), do: DateTime.compare(at, marker) == :gt

  # The latest progress: a step reaching done / verified / cancelled, a
  # person's transition or feedback on E or a step (system and agent
  # feedback never count).
  defp progress_marker(epic) do
    ids = [epic.id | Repo.all(from(t in Task, where: t.epic_id == ^epic.id, select: t.id))]

    step_done =
      from(e in TaskEvent,
        where:
          e.task_id in ^ids and e.task_id != ^epic.id and
            e.to_status in [:done, :verified, :cancelled],
        select: max(e.inserted_at)
      )

    human_event =
      from(e in TaskEvent,
        join: a in Actor,
        on: a.id == e.actor_id,
        where: e.task_id in ^ids and a.kind == :human,
        select: max(e.inserted_at)
      )

    human_feedback =
      from(f in Entry,
        join: a in Actor,
        on: a.id == f.author_id,
        where: f.task_id in ^ids and a.kind == :human,
        select: max(f.inserted_at)
      )

    [Repo.one(step_done), Repo.one(human_event), Repo.one(human_feedback)]
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&to_utc/1)
    |> Enum.max(DateTime, fn -> nil end)
  end

  defp to_utc(%DateTime{} = at), do: at
  defp to_utc(%NaiveDateTime{} = at), do: DateTime.from_naive!(at, "Etc/UTC")

  # The `epic_stalled` triggers ever queued on E, oldest first.
  defp stall_triggers(epic) do
    from(r in Run,
      where: r.task_id == ^epic.id,
      select: r.triggers
    )
    |> Repo.all()
    |> List.flatten()
    |> Enum.filter(&(&1["kind"] == "epic_stalled"))
    |> Enum.map(fn t ->
      {:ok, at, _} = DateTime.from_iso8601(t["at"])
      %{at: at, signature: t["signature"]}
    end)
    |> Enum.sort_by(& &1.at, DateTime)
  end

  defp wake(epic, loaded, snapshot, signature) do
    case Repo.get_by(TaskGrant, task_id: epic.id, agent_id: loaded.actor.id, kind: :assign) do
      nil ->
        :no_grant

      grant ->
        idle = idle(snapshot)

        trigger = %{
          kind: :epic_stalled,
          instructions: nil,
          extra: %{
            "idle" => Enum.map(Enum.take(idle, @max_listed), &idle_entry/1),
            "idle_count" => length(idle),
            "signature" => signature
          }
        }

        origin = %Origin{
          by_actor_id: system_id(epic.workspace_id),
          initiator_user_id: grant.root_initiator_user_id,
          chain: Enum.reject(grant.causal_agent_ids, &(&1 == loaded.leader.id))
        }

        case SquadDispatch.enqueue(origin, loaded, epic, trigger, lane: :work) do
          %Outcome{result: result} when result in [:queued, :merged, :deferred] ->
            Logger.info(
              "epic_watch woken epic=#{epic.ident} squad=#{loaded.actor.name} idle=#{length(idle)}"
            )

            :woken

          %Outcome{} ->
            :skipped
        end
    end
  end

  defp idle_entry(%{task: task, waiting_for: reason}) do
    %{
      "task" => task.ident,
      "reason" => Atom.to_string(reason),
      "assignee" => task.assignee_id && name(task.assignee_id)
    }
  end

  defp name(id), do: Repo.one(from(a in Actor, where: a.id == ^id, select: a.name))

  defp system_id(workspace_id),
    do:
      Repo.one!(
        from(a in Actor,
          where: a.workspace_id == ^workspace_id and a.kind == :system,
          select: a.id
        )
      )

  # One note per cycle.
  defp cap_note(epic, loaded, snapshot, marker) do
    system = Repo.get!(Actor, system_id(epic.workspace_id))

    notes =
      from(f in Entry,
        where:
          f.task_id == ^epic.id and f.author_id == ^system.id and
            fragment(
              "? @> jsonb_build_array(jsonb_build_object('reason', 'stall_capped'))",
              f.dispatch
            )
      )

    notes = if marker, do: where(notes, [f], f.inserted_at > ^marker), else: notes
    noted? = Repo.exists?(notes)

    unless noted? do
      Logger.info(
        "epic_watch capped epic=#{epic.ident} squad=#{loaded.actor.name} idle=#{length(idle(snapshot))}"
      )

      content =
        "Helmsman stopped waking #{loaded.leader.name} (leader of #{loaded.actor.name}): " <>
          "#{epic.ident} stalled #{config(:max_consecutive)} times with no step finished" <>
          since(marker) <>
          ". Idle steps: " <>
          idle_text(idle(snapshot)) <>
          ". A person needs to start, reassign or cancel them, or answer on #{epic.ident}; " <>
          "writing on #{epic.ident} lets Helmsman wake the leader again."

      {:ok, {entry, task}} =
        Feedback.insert_locked(epic, %Scope{actor: system}, %{kind: :comment, content: content},
          notify: false,
          mentions: []
        )

      outcome =
        Outcome.squad_skipped(loaded.leader, loaded.actor.name, :epic_stalled, :stall_capped)

      Feedback.finish_locked(task, entry, [outcome])
    end

    :ok
  end

  defp since(nil), do: ""
  defp since(at), do: " since " <> (at |> DateTime.truncate(:second) |> DateTime.to_iso8601())

  @doc "The idle steps as the prompt and notes list them: `ACC-12 (nes-ppu-apu: no run), ACC-13 (unassigned)`."
  @spec idle_text([Epics.step_state() | map()]) :: String.t()
  def idle_text(idle) do
    Enum.map_join(idle, ", ", fn
      %{task: task, waiting_for: :assignment} -> "#{task.ident} (unassigned)"
      %{task: task} -> "#{task.ident} (#{name(task.assignee_id)}: no run)"
      %{"task" => ident, "reason" => "assignment"} -> "#{ident} (unassigned)"
      %{"task" => ident, "assignee" => name} -> "#{ident} (#{name}: no run)"
    end)
  end

  @doc """
  For the claim check (`Helmsman.Runs.Revalidation`): whether the epic of
  `run`'s `epic_stalled` triggers is still stalled, the run itself left
  out; nil without such a trigger. Reads without locks under the caller's
  task lock.
  """
  @spec claim_state(Run.t()) :: :stalled | :not_stalled | nil
  def claim_state(%Run{task_id: task_id, triggers: triggers} = run) when is_integer(task_id) do
    if Enum.any?(triggers, &(&1["kind"] == "epic_stalled")) do
      epic = Repo.get!(Task, task_id)
      if stalled?(snapshot(epic, exclude_run_id: run.id)), do: :stalled, else: :not_stalled
    end
  end

  def claim_state(_run), do: nil
end
