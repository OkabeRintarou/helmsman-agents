defmodule Helmsman.Runs do
  @moduledoc """
  Runs (designs/13): creating and merging queued runs, cancelling them,
  reading them and the notifications that go with them.

  Triggers reach this module through `Helmsman.Dispatch`, inside the write
  transaction that caused them (designs/01 §4): `enqueue/3` checks the
  authorization source, the agent and its runtime, the trigger chain and
  the per-task rate, then adds the trigger to the queued run of the same
  `(task, agent, lane)` or creates one. Every notification is sent after
  the commit, once per transaction and run.
  """

  import Ecto.Query, warn: false

  alias Helmsman.Accounts.{Scope, User}
  alias Helmsman.Actors.Actor
  alias Helmsman.Agents
  alias Helmsman.Agents.AgentProfile
  alias Helmsman.Daemons.{Daemon, Runtime}
  alias Helmsman.Events
  alias Helmsman.Feedback
  alias Helmsman.Policy
  alias Helmsman.Repo
  alias Helmsman.Runs.{Origin, Outcome, Retry, Run, RunEvent}
  alias Helmsman.Tasks
  alias Helmsman.Tasks.{Ident, Task}
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
          optional(:lane) => :work | :reply
        }
  @type trigger :: %{kind: :assign | :manual, instructions: String.t() | nil}
  @type actor_ref :: %{name: String.t(), kind: String.t()} | nil
  @type summary :: %{
          required(:id) => pos_integer(),
          required(:task) => String.t() | nil,
          required(:agent) => String.t(),
          required(:agent_owner_id) => pos_integer(),
          required(:lane) => String.t(),
          required(:status) => String.t(),
          required(:triggers) => [map()],
          required(:failure_reason) => String.t() | nil,
          required(:priority) => 1..3,
          required(:attempt) => pos_integer(),
          required(:daemon) => String.t() | nil,
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

  Always returns `{:ok, outcome}`: not dispatching is a result, not a
  failure, so the transaction commits (with the system comment of a
  refused chain).
  """
  @spec enqueue(Origin.t(), target(), trigger()) :: {:ok, Outcome.t()}
  def enqueue(%Origin{} = origin, %{agent: %Actor{} = agent, profile: profile} = target, trigger) do
    kind = trigger.kind

    with :ok <- authorized(origin, agent),
         {:ok, runtime} <- available_runtime(profile),
         :ok <- check_chain(origin, agent, target.task) do
      attrs = %{
        workspace_id: agent.workspace_id,
        agent_id: agent.id,
        runtime_id: runtime.id,
        task_id: target.task && target.task.id,
        lane: Map.get(target, :lane, :work),
        trigger: trigger_entry(origin, agent, trigger),
        root_initiator_user_id: origin.initiator_user_id,
        causal_agent_ids: Enum.uniq(origin.chain ++ [agent.id]),
        capabilities: capabilities(profile, target.task),
        priority: priority(target.task)
      }

      case upsert_pending(attrs, rate_limit?: true) do
        {:skipped, reason} ->
          {:ok, Outcome.skipped(agent.name, kind, reason)}

        {result, %Run{} = run} ->
          {:ok, %Outcome{agent: agent.name, trigger: kind, result: result, run_id: run.id}}
      end
    else
      {:skip, reason} -> {:ok, Outcome.skipped(agent.name, kind, reason)}
    end
  end

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
      "feedback_id" => nil,
      "at" => DateTime.to_iso8601(DateTime.utc_now())
    }
  end

  @doc """
  The capabilities of a run (designs/13 §2.3, decision 5): `read`, with a
  task `write_task`, and `create_tasks` when the agent's profile has it.
  """
  @spec capabilities(AgentProfile.t(), Task.t() | nil) :: [String.t()]
  def capabilities(%AgentProfile{capabilities: caps}, task) do
    ["read"] ++
      if(task, do: ["write_task"], else: []) ++
      if("create_tasks" in (caps || []), do: ["create_tasks"], else: [])
  end

  defp priority(%Task{priority: :high}), do: 3
  defp priority(%Task{priority: :medium}), do: 2
  defp priority(_low_or_none), do: 1

  ## Merging

  @doc """
  Adds the trigger to the queued run of `(task_id, agent_id, lane)` or
  creates a run (decision 3, steps 4-6).

  `attrs`: `workspace_id`, `agent_id`, `runtime_id`, `task_id` (nil: never
  merged), `lane`, `trigger` (one entry of `triggers`) or `triggers` (the
  entries to add), `root_initiator_user_id`, `causal_agent_ids`,
  `capabilities` and `priority`; a retry (`Helmsman.Runs.Retry`) also
  gives `attempt`, `auto_retries`, `retry_of_id` and `not_before`, used
  only by a new run.

  1. The pending run of the key is locked `FOR UPDATE`; found → merged
     (trigger appended, causal chains united, the higher priority), without
     the rate check. A run being claimed is waited for and then no longer
     matches.
  2. Otherwise, with `rate_limit?: true` (the default) and a task, at least
     `config :helmsman, Helmsman.Dispatch, max_runs_per_task_per_hour`
     (default #{@default_rate}) runs created for the task in the last hour
     give `{:skipped, :rate_limited}`.
  3. `INSERT … ON CONFLICT` on the pending key: `:queued`, or `:merged`
     when a caller that does not hold the task lock inserted the key first.

  The run's notifications are registered for after the commit.
  """
  @spec upsert_pending(map(), keyword()) ::
          {:queued | :merged, Run.t()} | {:skipped, :rate_limited}
  def upsert_pending(attrs, opts \\ []) do
    case attrs.task_id && lock_pending(attrs) do
      %Run{} = run ->
        merged = merge(run.id, attrs)
        notify_run(merged)
        {:merged, merged}

      _none ->
        if Keyword.get(opts, :rate_limit?, true) and over_rate?(attrs.task_id),
          do: {:skipped, :rate_limited},
          else: insert(attrs)
    end
  end

  defp lock_pending(attrs) do
    Repo.one(
      from(r in Run,
        where:
          r.task_id == ^attrs.task_id and r.agent_id == ^attrs.agent_id and
            r.lane == ^attrs.lane and r.status in ^Run.pending_statuses(),
        lock: "FOR UPDATE"
      )
    )
  end

  @merge_set """
  triggers = runs.triggers || EXCLUDED.triggers,
  causal_agent_ids = ARRAY(SELECT DISTINCT unnest(runs.causal_agent_ids || EXCLUDED.causal_agent_ids) ORDER BY 1),
  priority = GREATEST(runs.priority, EXCLUDED.priority),
  updated_at = EXCLUDED.updated_at
  """

  @insert_sql """
  INSERT INTO runs (workspace_id, agent_id, runtime_id, task_id, lane, status, triggers,
    root_initiator_user_id, causal_agent_ids, capabilities, priority, inserted_at, updated_at,
    attempt, auto_retries, retry_of_id, not_before)
  VALUES ($1, $2, $3, $4, $5, 'queued', $6, $7, $8, $9, $10, $11, $11, $12, $13, $14,
    coalesce($15::timestamp, $11))
  ON CONFLICT (task_id, agent_id, lane) WHERE status IN ('deferred','queued')
  DO UPDATE SET #{@merge_set}
  RETURNING id, (xmax = 0)
  """

  defp insert(attrs) do
    %{rows: [[id, inserted?]]} = Repo.query!(@insert_sql, insert_params(attrs))
    run = Repo.get!(Run, id)

    if inserted? do
      notify_run(run, available: true)
      {:queued, run}
    else
      notify_run(run)
      {:merged, run}
    end
  end

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
      Map.get(attrs, :not_before)
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
        triggers = runs.triggers || $2,
        causal_agent_ids = ARRAY(SELECT DISTINCT unnest(runs.causal_agent_ids || $3::bigint[]) ORDER BY 1),
        priority = GREATEST(runs.priority, $4),
        updated_at = $5
      WHERE id = $1
      """,
      [id, triggers(attrs), attrs.causal_agent_ids, attrs.priority, DateTime.utc_now()]
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
        count
    end
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
  `:cancel_run` / `:retry_run`, without looking at its status. Pure.
  """
  @spec can?(Scope.t(), :cancel | :retry, summary()) :: boolean()
  def can?(%Scope{} = scope, action, %{initiator: initiator, agent_owner_id: owner_id})
      when action in [:cancel, :retry] do
    resource = %{initiator_id: initiator && initiator.id, agent_owner_id: owner_id}
    Policy.authorize(scope, :"#{action}_run", resource) == :ok
  end

  @doc """
  The number of active (`claimed`, `running`, `cancelling`) and pending
  runs of each agent among `agent_ids`, in one query:
  `%{agent_id => %{active: n, queued: n}}` (absent: none).
  """
  @spec counts([pos_integer()]) :: %{
          pos_integer() => %{active: non_neg_integer(), queued: non_neg_integer()}
        }
  def counts([]), do: %{}

  def counts(agent_ids) do
    active = Enum.map(Run.active_statuses(), &Atom.to_string/1)
    pending = Enum.map(Run.pending_statuses(), &Atom.to_string/1)

    from(r in Run,
      where:
        r.agent_id in ^agent_ids and
          r.status in ^(Run.active_statuses() ++ Run.pending_statuses()),
      group_by: r.agent_id,
      select:
        {r.agent_id,
         %{
           active: filter(count(r.id), fragment("? = ANY(?)", r.status, ^active)),
           queued: filter(count(r.id), fragment("? = ANY(?)", r.status, ^pending))
         }}
    )
    |> Repo.all()
    |> Map.new()
  end

  ## External form

  @doc """
  The summary of a run (decision 14, `add-run-lifecycle` decision 19):
  `%{id, task, agent, agent_owner_id, lane, status, triggers: [%{kind,
  by, at, instructions}] (a retry marker also has `auto` and `retry_of`),
  failure_reason, priority, attempt, daemon, initiator: %{id, name},
  retry_of_id, retry_run_id, events_seq, summary, usage,
  cancel_requested_by, claimed_at, started_at, finished_at, last_event_at,
  inserted_at, updated_at}`. Never the error text (`get/2`).
  """
  @spec summary(Run.t()) :: summary()
  def summary(%Run{} = run), do: hd(summaries([run]))

  defp summaries([]), do: []

  defp summaries(runs) do
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

    retries = Retry.targets(runs)

    Enum.map(runs, fn run ->
      %{
        id: run.id,
        task: run.task && run.task.ident,
        agent: run.agent.name,
        agent_owner_id: run.agent.owner_id,
        lane: Atom.to_string(run.lane),
        status: Atom.to_string(run.status),
        triggers: Enum.map(run.triggers, &trigger_view(&1, actors)),
        failure_reason: run.failure_reason && Atom.to_string(run.failure_reason),
        priority: run.priority,
        attempt: run.attempt,
        daemon: run.daemon_id && daemons[run.daemon_id],
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

  defp names(Daemon, ids),
    do: Map.new(Repo.all(from(d in Daemon, where: d.id in ^ids, select: {d.id, d.name})))

  defp names(User, ids),
    do: Map.new(Repo.all(from(u in User, where: u.id in ^ids, select: {u.id, u.display_name})))

  defp trigger_view(trigger, actors) do
    view = %{
      kind: trigger["kind"],
      by: actor_ref(actors[trigger["by_actor_id"]]),
      at: parse_at(trigger["at"]),
      instructions: trigger["instructions"]
    }

    if trigger["kind"] == "retry",
      do: Map.merge(view, %{auto: trigger["auto"] == true, retry_of: trigger["retry_of"]}),
      else: view
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

  ## Git (add-daemon-git-workspace)

  defdelegate prefetch_push_tokens(daemon_ctx), to: Helmsman.Runs.GitRepo
  defdelegate git_token(daemon_ctx, run_id), to: Helmsman.Runs.Pushes
  defdelegate pushed(daemon_ctx, report), to: Helmsman.Runs.Pushes

  @doc """
  Called once after a push record of `run` was committed
  (`add-daemon-git-workspace` decision 5). Does nothing yet but emit the
  `[:helmsman, :runs, :after_push]` telemetry event (`%{run_id: id}`);
  `add-pr-reconcile-merge` enqueues the pull request reconciliation here.
  """
  @spec after_push(Run.t()) :: :ok
  def after_push(%Run{id: id}) do
    :telemetry.execute([:helmsman, :runs, :after_push], %{}, %{run_id: id})
  end
end
