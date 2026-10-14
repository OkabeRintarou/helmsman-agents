defmodule Helmsman.Runs do
  @moduledoc """
  Runs (designs/13): creating and merging queued runs, cancelling them,
  reading them and the notifications that go with them.

  Triggers reach this module through `Helmsman.Dispatch`, inside the write
  transaction that caused them (designs/01 §4): `enqueue/3` checks the
  authorization source, the agent and its runtime, the trigger chain and
  the per-task rate, then adds the trigger to the queued run of the same
  `(task, agent, lane, squad)` or creates one. Every notification is sent after
  the commit, once per transaction and run.
  """

  import Ecto.Query, warn: false

  alias Helmsman.Accounts.{Scope, User}
  alias Helmsman.Actors.Actor
  alias Helmsman.AgentDesigns.SettleTurn
  alias Helmsman.Agents
  alias Helmsman.Agents.AgentProfile
  alias Helmsman.Daemons.{Daemon, Runtime}
  alias Helmsman.Dispatch.Dependencies
  alias Helmsman.Events
  alias Helmsman.Feedback
  alias Helmsman.GitHub.PullRequests
  alias Helmsman.Links
  alias Helmsman.Policy
  alias Helmsman.ProviderAccounts
  alias Helmsman.Repo
  alias Helmsman.Runs.{Origin, Outcome, Retry, Run, RunEvent, Triggers}
  alias Helmsman.Runs.Workers.SideEffect, as: SideEffectJob
  alias Helmsman.Tasks
  alias Helmsman.Tasks.{Ident, Task}
  alias Helmsman.Tx
  alias Helmsman.Workspaces.Workspace

  @max_chain 5
  @default_events 500
  @max_events 1000
  @default_rate 20
  @default_limit 50
  @max_limit 100

  @type target :: %{
          required(:agent) => Actor.t(),
          required(:profile) => AgentProfile.t(),
          required(:task) => Task.t() | nil,
          optional(:lane) => :work | :reply,
          optional(:squad_id) => pos_integer() | nil
        }
  @type trigger :: %{
          required(:kind) => Outcome.trigger(),
          required(:instructions) => String.t() | nil,
          optional(:feedback_id) => pos_integer() | nil,
          optional(:extra) => %{String.t() => term()}
        }
  @type actor_ref :: %{name: String.t(), kind: String.t()} | nil
  @type summary :: %{
          required(:id) => pos_integer(),
          required(:task) => String.t() | nil,
          required(:agent) => String.t(),
          required(:agent_owner_id) => pos_integer(),
          required(:squad) => %{id: pos_integer(), name: String.t()} | nil,
          required(:lane) => String.t(),
          required(:status) => String.t(),
          required(:triggers) => [map()],
          required(:failure_reason) => String.t() | nil,
          required(:priority) => 1..3,
          required(:attempt) => pos_integer(),
          required(:daemon) => String.t() | nil,
          required(:provider_account_name) => String.t() | nil,
          required(:provider_account) => ProviderAccounts.summary() | nil,
          required(:model) => String.t() | nil,
          required(:initiator) => %{id: pos_integer(), name: String.t() | nil},
          required(:retry_of_id) => pos_integer() | nil,
          required(:retry_run_id) => pos_integer() | nil,
          required(:events_seq) => non_neg_integer(),
          required(:summary) => String.t() | nil,
          required(:usage) => map() | nil,
          required(:cancel_requested_by) => actor_ref(),
          required(:claimed_at) => DateTime.t() | nil,
          required(:started_at) => DateTime.t() | nil,
          required(:finished_at) => DateTime.t() | nil,
          required(:last_event_at) => DateTime.t() | nil,
          required(:inserted_at) => DateTime.t(),
          required(:updated_at) => DateTime.t()
        }
  @type event_view :: %{seq: pos_integer(), type: String.t(), data: map(), at: DateTime.t()}

  ## Enqueueing

  @doc """
  Turns a trigger into a run of `target.agent` (decision 3). Call it inside
  the write transaction, with the agent's actor and profile rows locked
  `FOR SHARE` and, with a task, the task row `FOR UPDATE`.

  In order, the first failing check gives `%Outcome{result: :skipped}`:
  the origin may trigger the agent (`Helmsman.Agents.trigger_check/3`), it
  is bound to a runtime that is not disabled (the runtime row is locked
  `FOR SHARE`; an offline runtime is fine), the trigger chain
  (`check_chain/3`), then `upsert_pending/2` with the per-task rate limit.

  An assignment trigger (`Helmsman.Runs.Triggers.dependency_gated?/1`) for
  a task with unsatisfied prerequisites (`Helmsman.Links.blockers/1`)
  records them as `blocked_by` and asks for a `deferred` run; the outcome
  is then `:deferred` with `blocked_by` (`add-dependency-dispatch`
  decision 4). For such a trigger the caller must hold the workspace
  graph lock, so that a prerequisite cannot become satisfied unseen.

  Always returns `{:ok, outcome}`: not dispatching is a result, not a
  failure, so the transaction commits (with the system comment of a
  refused chain).
  """
  @spec enqueue(Origin.t(), target(), trigger()) :: {:ok, Outcome.t()}
  def enqueue(%Origin{} = origin, %{agent: %Actor{} = agent, profile: profile} = target, trigger) do
    kind = trigger.kind
    squad_id = Map.get(target, :squad_id)

    with :ok <- authorized(origin, agent),
         {:ok, runtime} <- available_runtime(profile),
         :ok <- check_chain(origin, agent, target.task) do
      {entry, status} = gate(trigger_entry(origin, agent, trigger), target.task)

      attrs = %{
        workspace_id: agent.workspace_id,
        agent_id: agent.id,
        runtime_id: runtime.id,
        task_id: target.task && target.task.id,
        lane: Map.get(target, :lane, :work),
        status: status,
        trigger: entry,
        root_initiator_user_id: origin.initiator_user_id,
        causal_agent_ids: Enum.uniq(origin.chain ++ [agent.id]),
        capabilities: capabilities(profile, target.task, [entry], squad_id),
        priority: if(kind == :design, do: 3, else: priority(target.task)),
        squad_id: squad_id
      }

      case upsert_pending(attrs, rate_limit?: true) do
        {:skipped, reason} ->
          {:ok, Outcome.skipped(agent, kind, reason)}

        {result, %Run{} = run} ->
          {:ok,
           %Outcome{
             agent: agent.name,
             agent_id: agent.id,
             trigger: kind,
             result: result,
             blocked_by: if(result == :deferred, do: entry["blocked_by"]),
             run_id: run.id
           }}
      end
    else
      {:skip, reason} -> {:ok, Outcome.skipped(agent, kind, reason)}
    end
  end

  # `add-dependency-dispatch` decision 4: an assignment trigger for a task
  # with unsatisfied prerequisites records them (`blocked_by`) and asks for
  # a `deferred` run. The caller holds the workspace graph lock then.
  defp gate(entry, %Task{id: task_id}) do
    with true <- Triggers.dependency_gated?([entry]),
         [_ | _] = blockers <- Links.blockers(task_id) do
      test_hook(:dependencies_read)
      {Map.put(entry, "blocked_by", blockers), :deferred}
    else
      _ -> {entry, :queued}
    end
  end

  defp gate(entry, nil), do: {entry, :queued}

  @doc """
  The checks a trigger needs before anything else (decision 6, step 3):
  the origin may trigger `agent` and the trigger chain allows it. A
  refused chain leaves the system comment on `task` (`check_chain/3`).
  """
  @spec check_trigger(Origin.t(), Actor.t(), Task.t() | nil) :: :ok | {:skip, Outcome.reason()}
  def check_trigger(%Origin{} = origin, %Actor{} = agent, task) do
    with :ok <- authorized(origin, agent), do: check_chain(origin, agent, task)
  end

  defp authorized(origin, agent) do
    case Agents.trigger_check(agent.workspace_id, origin.initiator_user_id, agent) do
      :ok -> :ok
      {:error, :not_managed} -> {:skip, :unauthorized}
      {:error, reason} -> {:skip, reason}
    end
  end

  # Locked FOR SHARE: `Helmsman.Runtimes.disable/2` locks the row FOR
  # UPDATE and cancels its queued runs, so either it sees this run or this
  # sees the runtime disabled.
  defp available_runtime(%AgentProfile{runtime_id: nil}), do: {:skip, :no_runtime}

  defp available_runtime(%AgentProfile{runtime_id: id}) do
    case Repo.one(from(r in Runtime, where: r.id == ^id, lock: "FOR SHARE")) do
      %Runtime{disabled_at: nil} = runtime -> {:ok, runtime}
      _disabled -> {:skip, :runtime_disabled}
    end
  end

  @doc """
  The trigger chain check (designs/13 §7): the target may not be on the
  chain of the trigger already, and the chain with it may not have more
  than #{@max_chain} agents. A refusal on a task leaves a comment by the
  system identity `helmsman` on it, in the transaction.
  """
  @spec check_chain(Origin.t(), Actor.t(), Task.t() | nil) ::
          :ok | {:skip, :loop_detected | :chain_too_long}
  def check_chain(%Origin{chain: chain}, %Actor{} = agent, task) do
    cond do
      agent.id in chain ->
        names = chain_names(chain)

        refuse(task, agent, :loop_detected, fn ->
          "#{agent.name} is already in the trigger chain (#{names}). " <>
            "This prevents agents from triggering each other in a loop."
        end)

      length(Enum.uniq(chain ++ [agent.id])) > @max_chain ->
        names = chain_names(chain ++ [agent.id])

        refuse(task, agent, :chain_too_long, fn ->
          "the trigger chain is longer than #{@max_chain} agents (#{names})."
        end)

      true ->
        :ok
    end
  end

  defp refuse(nil, _agent, reason, _text), do: {:skip, reason}

  defp refuse(%Task{} = task, agent, reason, text) do
    system =
      Repo.one!(
        from(a in Actor, where: a.workspace_id == ^task.workspace_id and a.kind == :system)
      )

    {:ok, {_entry, task}} =
      Feedback.insert_locked(task, %Scope{actor: system}, %{
        kind: :comment,
        content: "Did not start #{agent.name}: " <> text.()
      })

    Tasks.notify_summary(task)
    {:skip, reason}
  end

  defp chain_names(ids) do
    names =
      Map.new(Repo.all(from(a in Actor, where: a.id in ^ids, select: {a.id, a.name})))

    Enum.map_join(ids, " → ", &Map.get(names, &1, "?"))
  end

  defp trigger_entry(origin, agent, trigger) do
    %{
      "kind" => Atom.to_string(trigger.kind),
      "by_actor_id" => origin.by_actor_id,
      "initiator_user_id" => origin.initiator_user_id,
      "causal_agent_ids" => Enum.uniq(origin.chain ++ [agent.id]),
      "instructions" => trigger[:instructions],
      "feedback_id" => trigger[:feedback_id],
      "at" => DateTime.to_iso8601(DateTime.utc_now())
    }
    |> Map.merge(trigger[:extra] || %{})
  end

  @doc """
  The capabilities of a run (designs/13 §2.3, decision 5): `read`, with a
  task `write_task`, and `create_tasks` when the agent's profile has it.
  A design run (`design_run?/1` of its `triggers`) has exactly `read` and
  `design`, whatever the profile (`add-agent-conversation` decision 7).
  A run-only autopilot run (`autopilot_run?/1`) has `read`, and
  `create_tasks` only when its trigger says so, whatever the profile
  (`add-autopilots` decision 11).
  A run as a squad leader (`squad_id` set, `add-squads` decision 7) has
  `read`, `write_task` (with a task), `create_tasks` and `delegate`,
  whatever the profile.
  """
  @spec capabilities(AgentProfile.t(), Task.t() | nil, [map()], pos_integer() | nil) ::
          [String.t()]
  def capabilities(profile, task, triggers \\ [], squad_id \\ nil)

  def capabilities(%AgentProfile{capabilities: caps}, task, triggers, squad_id) do
    cond do
      design_run?(triggers) ->
        ["read", "design"]

      autopilot_run?(triggers) ->
        autopilot_capabilities(triggers)

      not is_nil(squad_id) ->
        ["read"] ++ if(task, do: ["write_task"], else: []) ++ ["create_tasks", "delegate"]

      true ->
        ["read"] ++
          if(task, do: ["write_task"], else: []) ++
          if("create_tasks" in (caps || []), do: ["create_tasks"], else: [])
    end
  end

  @doc """
  Whether a run is a design run (a turn of a creation conversation,
  `add-agent-conversation` decision 3): one of its triggers is `design`.
  Takes the run or its triggers.
  """
  @spec design_run?(Run.t() | [map()]) :: boolean()
  def design_run?(%Run{triggers: triggers}), do: design_run?(triggers)

  def design_run?(triggers) when is_list(triggers),
    do: Enum.any?(triggers, &(&1["kind"] == "design"))

  @doc """
  Whether a run is a run-only autopilot run (`add-autopilots` decision
  11): one of its triggers is `autopilot`. Takes the run or its triggers.
  """
  @spec autopilot_run?(Run.t() | [map()]) :: boolean()
  def autopilot_run?(%Run{triggers: triggers}), do: autopilot_run?(triggers)

  def autopilot_run?(triggers) when is_list(triggers),
    do: Enum.any?(triggers, &(&1["kind"] == "autopilot"))

  defp autopilot_capabilities(triggers) do
    if Enum.any?(triggers, &(&1["kind"] == "autopilot" and &1["create_tasks"] == true)),
      do: ["read", "create_tasks"],
      else: ["read"]
  end

  @doc "The conversation of a design run (its trigger's `design_id`), or nil."
  @spec design_id(Run.t()) :: pos_integer() | nil
  def design_id(%Run{triggers: triggers}),
    do: Enum.find_value(triggers, &(&1["kind"] == "design" && &1["design_id"]))

  defp priority(%Task{priority: :high}), do: 3
  defp priority(%Task{priority: :medium}), do: 2
  defp priority(_low_or_none), do: 1

  ## Merging

  @doc """
  Adds the trigger to the queued run of `(task_id, agent_id, lane,
  squad_id)` or creates a run (decision 3, steps 4-6; `add-squads`
  decision 2: a run as a squad leader never merges with one that is not).

  `attrs`: `workspace_id`, `agent_id`, `runtime_id`, `task_id` (nil: never
  merged), `lane`, `status` (`:queued`, the default, or `:deferred`, the
  status asked for: `add-dependency-dispatch` decision 4), `trigger` (one
  entry of `triggers`) or `triggers` (the
  entries to add), `root_initiator_user_id`, `causal_agent_ids`,
  `capabilities`, `priority` and optionally `squad_id`; a retry (`Helmsman.Runs.Retry`) also
  gives `attempt`, `auto_retries`, `retry_of_id` and `not_before`, used
  only by a new run.

  1. The pending run of the key is locked `FOR UPDATE`; found → merged
     (trigger appended, causal chains united, the higher priority; a
     `deferred` run asked to be `queued` becomes `queued`, a `queued` one
     stays `queued`), without the rate check. A run being claimed is
     waited for and then no longer matches.
  2. Otherwise, with `rate_limit?: true` (the default) and a task, at least
     `config :helmsman, Helmsman.Dispatch, max_runs_per_task_per_hour`
     (default #{@default_rate}) runs created for the task in the last hour
     give `{:skipped, :rate_limited}`.
  3. `INSERT … ON CONFLICT` on the pending key, with the same merge rules:
     `:queued`, or `:merged` when a caller that does not hold the task
     lock inserted the key first.

  The result is `:deferred` whenever the run is `deferred` afterwards
  (created or merged). The run's notifications are registered for after
  the commit; its daemon is told when it is new and `queued` or became
  `queued`.
  """
  @spec upsert_pending(map(), keyword()) ::
          {:queued | :merged | :deferred, Run.t()} | {:skipped, :rate_limited}
  def upsert_pending(attrs, opts \\ []) do
    case attrs.task_id && lock_pending(attrs) do
      %Run{} = run ->
        merged = merge(run.id, attrs)
        notify_run(merged, available: run.status == :deferred and merged.status == :queued)
        {merge_result(merged), merged}

      _none ->
        if Keyword.get(opts, :rate_limit?, true) and over_rate?(attrs.task_id),
          do: {:skipped, :rate_limited},
          else: insert(attrs)
    end
  end

  defp lock_pending(attrs) do
    query =
      from(r in Run,
        where:
          r.task_id == ^attrs.task_id and r.agent_id == ^attrs.agent_id and
            r.lane == ^attrs.lane and r.status in ^Run.pending_statuses(),
        lock: "FOR UPDATE"
      )

    query =
      case Map.get(attrs, :squad_id) do
        nil -> where(query, [r], is_nil(r.squad_id))
        squad_id -> where(query, [r], r.squad_id == ^squad_id)
      end

    Repo.one(query)
  end

  @merge_set """
  status = CASE WHEN EXCLUDED.status = 'queued' THEN 'queued' ELSE runs.status END,
  triggers = runs.triggers || EXCLUDED.triggers,
  causal_agent_ids = ARRAY(SELECT DISTINCT unnest(runs.causal_agent_ids || EXCLUDED.causal_agent_ids) ORDER BY 1),
  priority = GREATEST(runs.priority, EXCLUDED.priority),
  updated_at = EXCLUDED.updated_at
  """

  @insert_sql """
  INSERT INTO runs (workspace_id, agent_id, runtime_id, task_id, lane, status, triggers,
    root_initiator_user_id, causal_agent_ids, capabilities, priority, inserted_at, updated_at,
    attempt, auto_retries, retry_of_id, not_before, squad_id)
  VALUES ($1, $2, $3, $4, $5, $16, $6, $7, $8, $9, $10, $11, $11, $12, $13, $14,
    coalesce($15::timestamp, $11), $17)
  ON CONFLICT (task_id, agent_id, lane, coalesce(squad_id, 0))
    WHERE status IN ('deferred','queued')
  DO UPDATE SET #{@merge_set}
  RETURNING id, (xmax = 0), (SELECT r.status FROM runs r WHERE r.id = runs.id)
  """

  # The subquery of RETURNING reads the snapshot taken before the statement:
  # the merged row's status before the merge (NULL for a new row, and for a
  # row another transaction committed while this one waited for it).

  defp insert(attrs) do
    test_hook(:before_insert)
    %{rows: [[id, inserted?, before]]} = Repo.query!(@insert_sql, insert_params(attrs))
    run = Repo.get!(Run, id)

    if inserted? do
      notify_run(run, available: run.status == :queued)
      {if(run.status == :deferred, do: :deferred, else: :queued), run}
    else
      # `before` is nil when the conflicting row was committed after this
      # statement's snapshot (it waited for that insert): it may have been
      # deferred, so the daemon is told (once too often at worst).
      notify_run(run, available: before in [nil, "deferred"] and run.status == :queued)
      {merge_result(run), run}
    end
  end

  defp merge_result(%Run{status: :deferred}), do: :deferred
  defp merge_result(_run), do: :merged

  defp insert_params(attrs) do
    [
      attrs.workspace_id,
      attrs.agent_id,
      attrs.runtime_id,
      attrs.task_id,
      Atom.to_string(attrs.lane),
      triggers(attrs),
      attrs.root_initiator_user_id,
      attrs.causal_agent_ids,
      attrs.capabilities,
      attrs.priority,
      DateTime.utc_now(),
      Map.get(attrs, :attempt, 1),
      Map.get(attrs, :auto_retries, 0),
      Map.get(attrs, :retry_of_id),
      Map.get(attrs, :not_before),
      attrs |> Map.get(:status, :queued) |> Atom.to_string(),
      Map.get(attrs, :squad_id)
    ]
  end

  defp triggers(%{triggers: triggers}) when is_list(triggers), do: triggers
  defp triggers(%{trigger: trigger}), do: [trigger]

  # The same changes as the conflict clause of the insert, on a row this
  # transaction has locked.
  defp merge(id, attrs) do
    Repo.query!(
      """
      UPDATE runs SET
        status = CASE WHEN $6 = 'queued' THEN 'queued' ELSE runs.status END,
        triggers = runs.triggers || $2,
        causal_agent_ids = ARRAY(SELECT DISTINCT unnest(runs.causal_agent_ids || $3::bigint[]) ORDER BY 1),
        priority = GREATEST(runs.priority, $4),
        updated_at = $5
      WHERE id = $1
      """,
      [
        id,
        triggers(attrs),
        attrs.causal_agent_ids,
        attrs.priority,
        DateTime.utc_now(),
        attrs |> Map.get(:status, :queued) |> Atom.to_string()
      ]
    )

    Repo.get!(Run, id)
  end

  defp over_rate?(nil), do: false

  defp over_rate?(task_id) do
    since = DateTime.add(DateTime.utc_now(), -3600, :second)

    Repo.aggregate(
      from(r in Run, where: r.task_id == ^task_id and r.inserted_at > ^since),
      :count
    ) >=
      max_rate()
  end

  defp max_rate do
    :helmsman
    |> Application.get_env(Helmsman.Dispatch, [])
    |> Keyword.get(:max_runs_per_task_per_hour, @default_rate)
  end

  ## Cancelling and rebinding

  @doc """
  Cancels the pending (`deferred`, `queued`) runs among `queryable`, in the
  caller's transaction: locked `FOR UPDATE` (by ID), then `cancelled` with
  `reason`. Returns how many. Notifies after the commit.
  """
  @spec cancel_pending(Ecto.Queryable.t(), atom()) :: non_neg_integer()
  def cancel_pending(queryable, reason) do
    case lock_pending_ids(queryable) do
      [] ->
        0

      ids ->
        {count, runs} =
          Repo.update_all(
            from(r in Run, where: r.id in ^ids, select: r),
            set: [
              status: :cancelled,
              failure_reason: reason,
              finished_at: DateTime.utc_now(),
              updated_at: DateTime.utc_now()
            ]
          )

        Enum.each(runs, &notify_run/1)
        after_ended(runs)
        count
    end
  end

  @doc false
  # Called in the transaction that ended `runs` (any status before): a
  # design run gets the settlement of its turn
  # (`Helmsman.AgentDesigns.SettleTurn`, `add-agent-conversation`
  # decision 9); a delegated run that wakes its leader gets its
  # `delegate_done` effect (`add-squads` decision 9). Every path that ends
  # a run calls it: `Lifecycle.end!/3`, `cancel_pending/2` and
  # `Helmsman.Runs.Stop.cancel_for_initiator/2`. Also emits
  # `[:helmsman, :runs, :finished]` per run after the commit (the metric
  # `helmsman.runs.finished.count`).
  @spec after_ended([Run.t()]) :: :ok
  def after_ended(runs) do
    Enum.each(runs, fn run ->
      Tx.after_commit(fn ->
        :telemetry.execute([:helmsman, :runs, :finished], %{count: 1}, %{
          status: run.status,
          failure_reason: run.failure_reason
        })
      end)
    end)

    runs
    |> Enum.filter(&design_run?/1)
    |> Enum.each(fn run -> {:ok, _job} = Oban.insert(SettleTurn.new(%{run_id: run.id})) end)

    runs |> Enum.filter(&wakes_leader?/1) |> Enum.each(&delegate_done!/1)
    Helmsman.Autopilots.after_runs_ended(runs)
  end

  @doc false
  # Inserts the `delegate_done` effect of the ended delegated `run`, at
  # most once (`Helmsman.Runs.Workers.SideEffect` is unique per run and
  # kind): also by `Helmsman.Runs.Retry` when an automatic retry did not
  # requeue it.
  @spec delegate_done!(Run.t()) :: :ok
  def delegate_done!(%Run{id: id}) do
    {:ok, _job} = Oban.insert(SideEffectJob.new(%{run_id: id, kind: "delegate_done"}))
    :ok
  end

  @doc """
  Whether a run that ended wakes the leader that delegated it (`add-squads`
  decision 9): it has a `delegated` trigger and it succeeded, failed
  without an automatic retry, or was stopped other than by a person.
  """
  @spec wakes_leader?(Run.t()) :: boolean()
  def wakes_leader?(%Run{} = run) do
    delegated?(run) and
      case run.status do
        :succeeded -> true
        :failed -> not Retry.automatic?(run)
        :cancelled -> not stopped_by_person?(run)
        _other -> false
      end
  end

  @doc "Whether `run` has a `delegated` trigger."
  @spec delegated?(Run.t()) :: boolean()
  def delegated?(%Run{triggers: triggers}), do: Enum.any?(triggers, &(&1["kind"] == "delegated"))

  @doc false
  # Whether a person asked to stop `run` (rather than the system).
  @spec stopped_by_person?(Run.t()) :: boolean()
  def stopped_by_person?(%Run{cancel_requested_by_id: nil}), do: false

  def stopped_by_person?(%Run{cancel_requested_by_id: id}),
    do: Repo.exists?(from(a in Actor, where: a.id == ^id and a.kind == :human))

  @doc """
  The number of pending runs on the instance by status, `:queued` and
  `:deferred` (the metric `helmsman.runs.queued.count`).
  """
  @spec count_pending() :: %{queued: non_neg_integer(), deferred: non_neg_integer()}
  def count_pending do
    counts =
      Repo.all(
        from(r in Run,
          where: r.status in [:queued, :deferred],
          group_by: r.status,
          select: {r.status, count()}
        )
      )
      |> Map.new()

    %{queued: Map.get(counts, :queued, 0), deferred: Map.get(counts, :deferred, 0)}
  end

  @doc """
  Moves the pending runs of the agent `agent_id` to the runtime
  `runtime_id` (the agent was bound to another runtime), in the caller's
  transaction. The new runtime's daemon is told after the commit.
  """
  @spec rebind_pending(pos_integer(), pos_integer()) :: non_neg_integer()
  def rebind_pending(agent_id, runtime_id) do
    case lock_pending_ids(from(r in Run, where: r.agent_id == ^agent_id)) do
      [] ->
        0

      ids ->
        {count, runs} =
          Repo.update_all(
            from(r in Run, where: r.id in ^ids, select: r),
            set: [runtime_id: runtime_id, updated_at: DateTime.utc_now()]
          )

        Enum.each(runs, &notify_run(&1, available: true))
        count
    end
  end

  defp lock_pending_ids(queryable) do
    Repo.all(
      from(r in queryable,
        where: r.status in ^Run.pending_statuses(),
        order_by: r.id,
        lock: "FOR UPDATE",
        select: r.id
      )
    )
  end

  ## Notifications

  @doc false
  # Once per transaction and run (the latest summary); the daemon once per
  # transaction. `available: true` also tells the runtime's daemon.
  @spec notify_run(Run.t(), keyword()) :: :ok
  def notify_run(%Run{} = run, opts \\ []) do
    summary = summary(run)
    message = {:run_updated, summary}
    Events.after_commit_once(:run, Events.topic(:run, run.id), message)

    Events.after_commit_once(
      {:run, run.id},
      Events.topic(:workspace_runs, run.workspace_id),
      message
    )

    if run.task_id do
      Events.after_commit_once(
        :runs,
        Events.topic(:task, run.task_id),
        {:runs_changed, summary.task}
      )
    end

    if opts[:available], do: notify_daemon(run.runtime_id)
    :ok
  end

  defp notify_daemon(runtime_id) do
    query =
      from(r in Runtime,
        join: d in Daemon,
        on: d.id == r.daemon_id,
        where: r.id == ^runtime_id and is_nil(d.revoked_at),
        select: d.id
      )

    case Repo.one(query) do
      nil ->
        :ok

      daemon_id ->
        Events.after_commit_once(:runs, Events.topic(:daemon, daemon_id), {:runs_available})
    end
  end

  ## Reading

  @doc """
  The earliest run of the task that is `claimed`, `running` or
  `cancelling`, other than `exclude_run_id`: `%{id, agent}` or nil
  (decision 13).
  """
  @spec active_on_task(pos_integer(), pos_integer() | nil) ::
          %{id: pos_integer(), agent: String.t()} | nil
  def active_on_task(task_id, exclude_run_id) do
    query =
      from(r in Run,
        join: a in Actor,
        on: a.id == r.agent_id,
        where: r.task_id == ^task_id and r.status in ^Run.active_statuses(),
        order_by: [asc: r.inserted_at, asc: r.id],
        limit: 1,
        select: %{id: r.id, agent: a.name}
      )

    query = if exclude_run_id, do: where(query, [r], r.id != ^exclude_run_id), else: query
    Repo.one(query)
  end

  @doc """
  The runs of the task `ident`, newest first, at most #{@default_limit}
  (`:view_runs`).
  """
  @spec list_for_task(Scope.t(), String.t()) ::
          {:ok, [summary()]} | {:error, :forbidden | :not_found}
  def list_for_task(%Scope{workspace: %Workspace{id: workspace_id}} = scope, ident)
      when is_binary(ident) do
    with :ok <- Policy.authorize(scope, :view_runs),
         {:ok, ident, _key, _seq} <- Ident.parse(ident),
         %Task{} = task <-
           Repo.one(from(t in Task, where: t.workspace_id == ^workspace_id and t.ident == ^ident)) do
      runs =
        Repo.all(
          from(r in Run,
            where: r.task_id == ^task.id,
            order_by: [desc: r.inserted_at, desc: r.id],
            limit: @default_limit
          )
        )

      {:ok, summaries(runs)}
    else
      nil -> {:error, :not_found}
      error -> error
    end
  end

  @doc """
  The runs of the agent `name`, newest first (`:view_runs`).

  ## Options

    * `:limit` - at most this many (default #{@default_limit}, at most
      #{@max_limit})
    * `:before` - `{inserted_at, id}` of the last run of the previous page
  """
  @spec list_for_agent(Scope.t(), String.t(), keyword()) ::
          {:ok, [summary()]} | {:error, :forbidden | :not_found}
  def list_for_agent(%Scope{workspace: %Workspace{id: workspace_id}} = scope, name, opts \\ [])
      when is_binary(name) do
    with :ok <- Policy.authorize(scope, :view_runs),
         %Actor{} = agent <-
           Repo.one(
             from(a in Actor,
               where: a.workspace_id == ^workspace_id and a.name == ^name and a.kind == :agent
             )
           ) do
      runs =
        from(r in Run,
          where: r.agent_id == ^agent.id,
          order_by: [desc: r.inserted_at, desc: r.id],
          limit: ^limit(opts[:limit])
        )
        |> before(opts[:before])
        |> Repo.all()

      {:ok, summaries(runs)}
    else
      nil -> {:error, :not_found}
      error -> error
    end
  end

  defp limit(n) when is_integer(n), do: n |> max(1) |> min(@max_limit)
  defp limit(_), do: @default_limit

  defp before(query, nil), do: query

  defp before(query, {%DateTime{} = inserted_at, id}) when is_integer(id),
    do: where(query, [r], fragment("(?, ?) < (?, ?)", r.inserted_at, r.id, ^inserted_at, ^id))

  @doc """
  The run `id` of the scope's workspace (`:view_runs`): its summary, with
  `error` (the error text) for those who may read its execution events
  (`:view_run_events`, member and above).
  """
  @spec get(Scope.t(), integer()) ::
          {:ok, summary() | map()} | {:error, :forbidden | :not_found}
  def get(%Scope{workspace: %Workspace{id: workspace_id}} = scope, id) when is_integer(id) do
    with :ok <- Policy.authorize(scope, :view_runs),
         %Run{} = run <-
           Repo.one(from(r in Run, where: r.workspace_id == ^workspace_id and r.id == ^id)) do
      case Policy.authorize(scope, :view_run_events) do
        :ok -> {:ok, Map.put(summary(run), :error, run.error)}
        {:error, :forbidden} -> {:ok, summary(run)}
      end
    else
      nil -> {:error, :not_found}
      error -> error
    end
  end

  @doc """
  The execution events of the run `run_id` (`:view_run_events`), by
  sequence number: `%{events: [event_view], pruned: boolean, last_seq}`.
  `last_seq` is the run's last saved sequence number; a pruned run has no
  events left.

  ## Options

    * `:after_seq` - the events after this one (default 0)
    * `:before_seq` - instead, the events right before this one
    * `:latest` - `true`: instead, the latest events
    * `:limit` - at most this many (default #{@default_events}, at most #{@max_events})
  """
  @spec list_events(Scope.t(), integer(), keyword()) ::
          {:ok, %{events: [event_view()], pruned: boolean(), last_seq: non_neg_integer()}}
          | {:error, :forbidden | :not_found}
  def list_events(%Scope{workspace: %Workspace{id: workspace_id}} = scope, run_id, opts \\ [])
      when is_integer(run_id) do
    with :ok <- Policy.authorize(scope, :view_run_events),
         %Run{} = run <-
           Repo.one(from(r in Run, where: r.workspace_id == ^workspace_id and r.id == ^run_id)) do
      limit = opts[:limit] |> event_limit()

      events =
        if run.events_pruned_at,
          do: [],
          else: run |> events_page(opts, limit) |> Enum.map(&event_view/1)

      {:ok, %{events: events, pruned: not is_nil(run.events_pruned_at), last_seq: run.events_seq}}
    else
      nil -> {:error, :not_found}
      error -> error
    end
  end

  defp event_limit(n) when is_integer(n), do: n |> max(1) |> min(@max_events)
  defp event_limit(_), do: @default_events

  # Only events up to the run's `events_seq` as read with it: they were
  # saved in the transaction that raised it, so `last_seq` and the events
  # are one snapshot even while more arrive.
  defp events_page(run, opts, limit) do
    base = from(e in RunEvent, where: e.run_id == ^run.id and e.seq <= ^run.events_seq)

    cond do
      opts[:latest] == true ->
        latest(base, limit)

      is_integer(opts[:before_seq]) ->
        latest(where(base, [e], e.seq < ^opts[:before_seq]), limit)

      true ->
        after_seq = Keyword.get(opts, :after_seq, 0)

        Repo.all(
          from(e in base, where: e.seq > ^after_seq, order_by: [asc: e.seq], limit: ^limit)
        )
    end
  end

  defp latest(query, limit),
    do:
      from(e in query, order_by: [desc: e.seq], limit: ^limit)
      |> Repo.all()
      |> Enum.reverse()

  @doc """
  The external form of an execution event, in `list_events/3` and in the
  `{:run_events, run_id, [event_view]}` notification: `%{seq, type, data,
  at}`, `type` a string, `data` with string keys.
  """
  @spec event_view(RunEvent.t() | map()) :: event_view()
  def event_view(%{seq: seq, type: type, data: data, at: at}),
    do: %{seq: seq, type: to_string(type), data: data, at: at}

  @doc """
  Whether `scope` may stop (`:cancel`) or retry (`:retry`) the run of
  `summary` (`summary/1`), by the rule of `Helmsman.Policy` for
  `:cancel_run` / `:retry_run`, without looking at its status. A run
  started by an autopilot (`autopilot` trigger) is never retryable. Pure.
  """
  @spec can?(Scope.t(), :cancel | :retry, summary()) :: boolean()
  def can?(%Scope{} = scope, action, %{initiator: initiator, agent_owner_id: owner_id} = summary)
      when action in [:cancel, :retry] do
    if action == :retry and autopilot_summary?(summary),
      do: false,
      else: can_run?(scope, action, initiator, owner_id)
  end

  # `add-autopilots` decision 11: a run-only autopilot run is never retried
  # (`not_retryable`); "run now" starts another one.
  defp autopilot_summary?(summary),
    do: Enum.any?(Map.get(summary, :triggers, []), &(&1[:kind] == "autopilot"))

  defp can_run?(scope, action, initiator, owner_id) do
    resource = %{initiator_id: initiator && initiator.id, agent_owner_id: owner_id}
    Policy.authorize(scope, :"#{action}_run", resource) == :ok
  end

  @doc """
  The number of active (`claimed`, `running`, `cancelling`) and pending
  runs of each agent among `agent_ids`, and when its latest run was
  created, in one query: `%{agent_id => %{active: n, queued: n,
  last_run_at: datetime}}` (absent: no run).
  """
  @spec counts([pos_integer()]) :: %{
          pos_integer() => %{
            active: non_neg_integer(),
            queued: non_neg_integer(),
            last_run_at: DateTime.t()
          }
        }
  def counts([]), do: %{}

  def counts(agent_ids) do
    active = Enum.map(Run.active_statuses(), &Atom.to_string/1)
    pending = Enum.map(Run.pending_statuses(), &Atom.to_string/1)

    from(r in Run,
      where: r.agent_id in ^agent_ids,
      group_by: r.agent_id,
      select:
        {r.agent_id,
         %{
           active: filter(count(r.id), fragment("? = ANY(?)", r.status, ^active)),
           queued: filter(count(r.id), fragment("? = ANY(?)", r.status, ^pending)),
           last_run_at: max(r.inserted_at)
         }}
    )
    |> Repo.all()
    |> Map.new()
  end

  ## External form

  @doc """
  The summary of a run (decision 14, `add-run-lifecycle` decision 19):
  `%{id, task, agent, agent_owner_id, lane, status, triggers: [%{kind,
  by, at, instructions}] (a retry marker also has `auto` and `retry_of`;
  `delegate_done` has `member`; `autopilot` has `autopilot: %{id, name}`,
  nil once deleted, and `source`: "schedule" | "manual" | "webhook"),
  failure_reason, priority, attempt, daemon, provider_account_name (the
  account the claim used; nil: none or deleted), provider_account (its
  summary, `Helmsman.ProviderAccounts.summaries/1`, or nil), model (the
  model the claim sent; nil: none or the default), initiator: %{id, name},
  retry_of_id, retry_run_id, events_seq, summary, usage,
  cancel_requested_by, claimed_at, started_at, finished_at, last_event_at,
  inserted_at, updated_at}`. Never the error text (`get/2`).
  """
  @spec summary(Run.t()) :: summary()
  def summary(%Run{} = run), do: hd(summaries([run]))

  @doc """
  The summaries of `runs`, in their order, with a fixed number of queries
  whatever their number (the batch form of `summary/1`).
  """
  @spec summaries([Run.t()]) :: [summary()]
  def summaries([]), do: []

  def summaries(runs) do
    runs = Repo.preload(runs, [:agent, :task])

    actor_ids =
      runs
      |> Enum.flat_map(fn run ->
        [run.cancel_requested_by_id | Enum.map(run.triggers, & &1["by_actor_id"])]
      end)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    actors = Map.new(Repo.all(from(a in Actor, where: a.id in ^actor_ids)), &{&1.id, &1})
    daemons = names(Daemon, runs |> Enum.map(& &1.daemon_id) |> Enum.reject(&is_nil/1))
    users = names(User, Enum.map(runs, & &1.root_initiator_user_id))

    accounts =
      ProviderAccounts.summaries(
        runs
        |> Enum.map(& &1.provider_account_id)
        |> Enum.reject(&is_nil/1)
      )

    retries = Retry.targets(runs)
    squads = squad_names(runs |> Enum.map(& &1.squad_id) |> Enum.reject(&is_nil/1))
    lookups = %{actors: actors, autopilots: autopilot_names(runs)}

    Enum.map(runs, fn run ->
      %{
        id: run.id,
        task: run.task && run.task.ident,
        agent: run.agent.name,
        squad: run.squad_id && %{id: run.squad_id, name: squads[run.squad_id]},
        agent_owner_id: run.agent.owner_id,
        lane: Atom.to_string(run.lane),
        status: Atom.to_string(run.status),
        triggers: Enum.map(run.triggers, &trigger_view(&1, run.workspace_id, lookups)),
        failure_reason: run.failure_reason && Atom.to_string(run.failure_reason),
        priority: run.priority,
        attempt: run.attempt,
        daemon: run.daemon_id && daemons[run.daemon_id],
        provider_account_name:
          run.provider_account_id && get_in(accounts, [run.provider_account_id, :name]),
        provider_account: run.provider_account_id && accounts[run.provider_account_id],
        model: run.model,
        initiator: %{
          id: run.root_initiator_user_id,
          name: users[run.root_initiator_user_id]
        },
        retry_of_id: run.retry_of_id,
        retry_run_id: retries[run.id],
        events_seq: run.events_seq,
        summary: run.summary,
        usage: run.usage,
        cancel_requested_by: actor_ref(actors[run.cancel_requested_by_id]),
        claimed_at: run.claimed_at,
        started_at: run.started_at,
        finished_at: run.finished_at,
        last_event_at: run.last_event_at,
        inserted_at: run.inserted_at,
        updated_at: run.updated_at
      }
    end)
  end

  # `add-squads` decision 4: the squad a run works as.
  defp squad_names([]), do: %{}

  defp squad_names(ids),
    do:
      Map.new(
        Repo.all(
          from(s in Helmsman.Squads.Squad,
            join: a in Actor,
            on: a.id == s.actor_id,
            where: s.id in ^Enum.uniq(ids),
            select: {s.id, a.name}
          )
        )
      )

  # `add-autopilots` decision 11: the autopilot that started a run-only
  # run, keyed by `{workspace_id, id}` so that a run never names another
  # workspace's autopilot; absent when it was deleted since.
  defp autopilot_names(runs) do
    keys =
      for run <- runs,
          %{"kind" => "autopilot", "autopilot_id" => id} <- run.triggers,
          is_integer(id),
          uniq: true,
          do: {run.workspace_id, id}

    if keys == [] do
      %{}
    else
      ids = keys |> Enum.map(&elem(&1, 1)) |> Enum.uniq()
      workspace_ids = keys |> Enum.map(&elem(&1, 0)) |> Enum.uniq()

      Map.new(
        Repo.all(
          from(a in Helmsman.Autopilots.Autopilot,
            where: a.id in ^ids and a.workspace_id in ^workspace_ids,
            select: {{a.workspace_id, a.id}, a.name}
          )
        )
      )
    end
  end

  defp names(Daemon, ids),
    do: Map.new(Repo.all(from(d in Daemon, where: d.id in ^ids, select: {d.id, d.name})))

  defp names(User, ids),
    do: Map.new(Repo.all(from(u in User, where: u.id in ^ids, select: {u.id, u.display_name})))

  defp trigger_view(trigger, workspace_id, lookups) do
    view = %{
      kind: trigger["kind"],
      by: actor_ref(lookups.actors[trigger["by_actor_id"]]),
      at: parse_at(trigger["at"]),
      instructions: trigger["instructions"]
    }

    case trigger["kind"] do
      "retry" -> Map.merge(view, %{auto: trigger["auto"] == true, retry_of: trigger["retry_of"]})
      # `add-squads` decision 9: the member whose delegated run ended.
      "delegate_done" -> Map.put(view, :member, view.by)
      "autopilot" -> Map.merge(view, autopilot_view(trigger, workspace_id, lookups.autopilots))
      _other -> view
    end
  end

  defp autopilot_view(trigger, workspace_id, names) do
    id = trigger["autopilot_id"]

    %{
      autopilot: (name = names[{workspace_id, id}]) && %{id: id, name: name},
      source: trigger["source"]
    }
  end

  defp actor_ref(nil), do: nil
  defp actor_ref(%Actor{name: name, kind: kind}), do: %{name: name, kind: Atom.to_string(kind)}

  defp parse_at(at) when is_binary(at) do
    case DateTime.from_iso8601(at) do
      {:ok, datetime, _offset} -> datetime
      _error -> nil
    end
  end

  defp parse_at(_at), do: nil

  ## Lifecycle (add-run-lifecycle)

  defdelegate revalidate(run, locked), to: Helmsman.Runs.Revalidation, as: :check
  defdelegate claim(daemon_ctx, base_url, push_tokens \\ %{}), to: Helmsman.Runs.Claim
  defdelegate starting(daemon_ctx, run_id), to: Helmsman.Runs.Lifecycle
  defdelegate started(daemon_ctx, report), to: Helmsman.Runs.Lifecycle
  defdelegate append_events(daemon_ctx, run_id, events), to: Helmsman.Runs.Lifecycle
  defdelegate finish(daemon_ctx, report), to: Helmsman.Runs.Lifecycle
  defdelegate reconcile(daemon_ctx, run_ids, mode), to: Helmsman.Runs.Lifecycle
  defdelegate cancel(scope, run_id), to: Helmsman.Runs.Stop
  defdelegate stop_active(queryable), to: Helmsman.Runs.Stop
  defdelegate cancel_for_initiator(workspace_id, user_id), to: Helmsman.Runs.Stop
  defdelegate retry(scope, run_id), to: Helmsman.Runs.Retry

  ## Steering (add-run-steering)

  defdelegate steer_ack(daemon_ctx, run_id, feedback_id), to: Helmsman.Runs.Steering, as: :ack
  defdelegate unacked_steers(daemon_ctx, run_ids), to: Helmsman.Runs.Steering, as: :unacked
  defdelegate steerable(scope, ident), to: Helmsman.Runs.Steering

  ## Git (add-daemon-git-workspace)

  defdelegate prefetch_push_tokens(daemon_ctx), to: Helmsman.Runs.GitRepo
  defdelegate git_token(daemon_ctx, run_id), to: Helmsman.Runs.Pushes
  defdelegate pushed(daemon_ctx, report), to: Helmsman.Runs.Pushes

  ## Worktree cleanup (add-pr-reconcile-merge)

  defdelegate cleanup_check(daemon_ctx, items), to: Helmsman.Runs.Cleanup, as: :check

  @doc """
  Called once after a push record of `run` was committed
  (`add-daemon-git-workspace` decision 5): emits the
  `[:helmsman, :runs, :after_push]` telemetry event (`%{run_id: id}`) and
  wakes the pull request reconciliation of its task when it has a
  repository (`add-pr-reconcile-merge` decision 4).
  """
  @spec after_push(Run.t()) :: :ok
  def after_push(%Run{id: id} = run) do
    :telemetry.execute([:helmsman, :runs, :after_push], %{}, %{run_id: id})

    if run.repository_id && run.task_id,
      do: PullRequests.wake(run.task_id),
      else: :ok
  end

  @doc """
  Called in the transaction of every write that ends a `claimed`,
  `running` or `cancelling` run (`Helmsman.Runs.Lifecycle.end!/3`, the
  only such path: finishing, stopping, the sweep's lease and offline
  judgements, the restart reaping and the start-time checks): wakes the
  pull request reconciliation of its task when the task's project is
  bound to a GitHub repository (`add-pr-reconcile-merge` decision 4,
  designs/13 §4.4) and registers the re-check of the tasks depending on
  it (`Helmsman.Dispatch.Dependencies.changed/1`, `add-dependency-dispatch`
  decision 6).
  """
  @spec after_terminal(Run.t()) :: :ok
  def after_terminal(%Run{task_id: task_id}) do
    :ok = Dependencies.changed(task_id)
    PullRequests.wake_if_bound(task_id)
  end

  # Fault injection for the concurrency tests: compiled in the test
  # environment only.
  if Mix.env() == :test do
    defp test_hook(point) do
      case Process.get(:helmsman_test_hook) do
        hook when is_function(hook, 1) -> hook.(point)
        _ -> :ok
      end
    end
  else
    defp test_hook(_point), do: :ok
  end

  ## Read models (add-run-read-models)

  defdelegate active_agents(scope, idents), to: Helmsman.Runs.ReadModels
  defdelegate usage_for_agent(scope, name, opts \\ []), to: Helmsman.Runs.ReadModels
  defdelegate list_open(scope, target, opts \\ []), to: Helmsman.Runs.ReadModels
  defdelegate list_finished(scope, target, opts \\ []), to: Helmsman.Runs.ReadModels
end
