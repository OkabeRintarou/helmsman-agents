defmodule Helmsman.Runs.Steering do
  @moduledoc """
  Steering a running run with feedback (designs/13 §8, `add-run-steering`).

  A person adding feedback may name the task's running run R
  (`Helmsman.Feedback.add/3`, `steer_run_id`). When the author may trigger
  R's agent A, the triggers the record causes for A carry `steer_run_id`
  and, when none of them was queued, a `steer` trigger is enqueued as the
  fallback (decisions 3, 5). Only when the fallback is queued and R is
  `running` is the record pushed to R's daemon after the commit and a
  `run_steers` row written (decision 3, step 5): pushing and the fallback
  happen together or not at all.

  The daemon acknowledges the push once the CLI took it (`ack/3`,
  decision 6). A trigger waiting for R is settled — removed from its
  queued run — only when R `succeeded` and the push was acknowledged
  (`settled?/2`, decision 7): actively after R ends (`settle/1`, the
  `steer_settle` side effect) and again when a run is claimed or started
  (`Helmsman.Runs.Revalidation`).
  """

  import Ecto.Query, warn: false

  require Logger

  alias Ecto.Changeset
  alias Helmsman.Accounts.Scope
  alias Helmsman.Actors.Actor
  alias Helmsman.Agents
  alias Helmsman.Agents.AgentProfile
  alias Helmsman.Dispatch.Continuation
  alias Helmsman.Events
  alias Helmsman.Feedback
  alias Helmsman.Feedback.{Entry, Id, Replies}
  alias Helmsman.Policy
  alias Helmsman.Repo
  alias Helmsman.Runs
  alias Helmsman.Runs.{Lifecycle, Origin, Outcome, Prompt, Revalidation, Run, RunSteer, Triggers}
  alias Helmsman.Squads
  alias Helmsman.Squads.Dispatch, as: SquadDispatch
  alias Helmsman.Squads.Squad
  alias Helmsman.Tasks.{Ident, Task}
  alias Helmsman.Tx
  alias Helmsman.Workspaces.Workspace

  @closed [:verified, :cancelled]
  @live_providers [:codex, :claude]
  @ackable [:running, :cancelling]

  @type facts :: %{
          {pos_integer(), pos_integer()} => %{
            status: Run.status(),
            acked_at: DateTime.t() | nil
          }
        }
  @type view :: %{
          run_id: pos_integer(),
          agent: String.t(),
          sent_at: DateTime.t(),
          acked_at: DateTime.t() | nil
        }
  @type steerable :: %{
          run_id: pos_integer(),
          agent: String.t(),
          live: boolean(),
          allowed: boolean(),
          reason: atom() | nil
        }

  @doc """
  The providers whose CLI takes input while it runs (decision 10, 12).
  """
  @spec live_providers() :: [atom()]
  def live_providers, do: @live_providers

  ## Requesting (decision 3)

  @doc """
  Checks the `steer_run_id` given to `Helmsman.Feedback.add/3`, before the
  transaction: nil (none), or a positive integer (or its decimal string)
  given by a person. Field errors on `steer_run_id` otherwise.
  """
  @spec check_request(Scope.t(), term()) :: {:ok, pos_integer() | nil} | {:error, Changeset.t()}
  def check_request(_scope, nil), do: {:ok, nil}

  def check_request(%Scope{actor: actor}, value) do
    case parse_id(value) do
      nil ->
        {:error, field_error("must be a positive integer")}

      id ->
        if match?(%Actor{kind: :human}, actor),
          do: {:ok, id},
          else: {:error, field_error("only people can send feedback to a running agent")}
    end
  end

  defp parse_id(id) when is_integer(id) and id > 0, do: id

  defp parse_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {n, ""} when n > 0 -> n
      _other -> nil
    end
  end

  defp parse_id(_id), do: nil

  @doc false
  @spec field_error(String.t()) :: Changeset.t()
  def field_error(message),
    do: %Entry{} |> Changeset.change() |> Changeset.add_error(:steer_run_id, message)

  @doc """
  The agent of the run `run_id` (nil: none), read without locks: a
  candidate target of `Helmsman.Dispatch.Targets.with_locked/4`.
  """
  @spec guess(pos_integer(), pos_integer() | nil) :: [pos_integer()]
  def guess(_workspace_id, nil), do: []

  def guess(workspace_id, run_id) do
    Repo.all(
      from(r in Run,
        left_join: s in Squad,
        on: s.id == r.squad_id,
        where: r.id == ^run_id and r.workspace_id == ^workspace_id,
        select: [r.agent_id, s.actor_id]
      )
    )
    |> List.flatten()
    |> Enum.reject(&is_nil/1)
  end

  @doc """
  The run `run_id` when it is a run of the locked `task` (nil: no steering);
  a field error otherwise. Read under the task row lock, not locked itself.
  """
  @spec target(Task.t(), pos_integer() | nil) ::
          {:ok, Run.t() | nil} | {:error, Changeset.t()}
  def target(_task, nil), do: {:ok, nil}

  def target(%Task{} = task, run_id) do
    case Repo.get_by(Run, id: run_id, workspace_id: task.workspace_id) do
      %Run{task_id: task_id} = run when task_id == task.id -> {:ok, run}
      _other -> {:error, field_error("is not a run of #{task.ident}")}
    end
  end

  @doc """
  The agent IDs `target/2`'s result adds to the locked targets; for a run
  as a squad leader also the squad identity (its rows are locked too,
  `add-squads` decision 6).
  """
  @spec target_ids({:ok, Run.t() | nil} | {:error, term()}) :: [pos_integer()]
  def target_ids({:ok, %Run{agent_id: id, squad_id: nil}}), do: [id]

  def target_ids({:ok, %Run{agent_id: id, squad_id: squad_id}}),
    do: [id | Repo.all(from(s in Squad, where: s.id == ^squad_id, select: s.actor_id))]

  def target_ids(_none), do: []

  @doc """
  Runs the feedback plan of `entry` (`Helmsman.Dispatch.Continuation.run_feedback/5`)
  with the steering of `run` (nil: none), in the transaction that inserted
  `entry` (decision 3, steps 3–5). The agent's rows and the task row are
  locked. Returns the outcomes.
  """
  @spec run_feedback(Scope.t(), Continuation.plan(), Task.t(), Entry.t(), Run.t() | nil) ::
          [Outcome.t()]
  def run_feedback(scope, plan, task, entry, nil),
    do: Continuation.run_feedback(scope, plan, task, entry)

  def run_feedback(%Scope{} = scope, plan, %Task{} = task, %Entry{} = entry, %Run{} = run) do
    agent = Repo.get!(Actor, run.agent_id)

    case steer_check(scope, task, agent, run) do
      {:squad, outcome} ->
        Continuation.run_feedback(scope, plan, task, entry) ++ [%{outcome | steer_run_id: run.id}]

      :ok ->
        outcomes =
          Continuation.run_feedback(scope, plan, task, entry, steer: {agent.id, run.id})

        outcomes =
          if Enum.any?(outcomes, &fallback_queued?(&1, run)),
            do: outcomes,
            else: outcomes ++ [enqueue(scope, Repo.reload!(task), agent, run, entry)]

        if Enum.any?(outcomes, &fallback_queued?(&1, run)), do: push(run, entry)
        outcomes

      {:error, reason} ->
        Continuation.run_feedback(scope, plan, task, entry) ++
          [%{Outcome.skipped(agent, :steer, refusal(reason)) | steer_run_id: run.id}]
    end
  end

  defp refusal(:not_managed), do: :unauthorized
  defp refusal(reason), do: reason

  # Steering a run as a squad leader: the author must be allowed to trigger
  # the squad (`add-squads` decision 6).
  defp steer_check(scope, task, agent, %Run{squad_id: nil}),
    do: Agents.trigger_check(task.workspace_id, scope.user.id, agent)

  defp steer_check(scope, _task, _agent, %Run{squad_id: squad_id}) do
    case SquadDispatch.check(Origin.from_scope(scope), Squads.load(squad_id), :steer) do
      :ok -> :ok
      {:skip, outcome} -> {:squad, outcome}
    end
  end

  defp fallback_queued?(%Outcome{} = outcome, run),
    do:
      outcome.agent_id == run.agent_id and outcome.steer_run_id == run.id and
        outcome.result in [:queued, :merged]

  # Decision 5: authorized by the author, chain `[A]`, in R's lane.
  defp enqueue(scope, task, agent, run, entry) do
    outcome =
      if run.lane == :work and task.status in @closed do
        Outcome.skipped(agent, :steer, :task_closed)
      else
        profile = Repo.one!(from(p in AgentProfile, where: p.actor_id == ^agent.id))
        target = %{agent: agent, profile: profile, task: task, lane: run.lane}

        trigger = %{
          kind: :steer,
          instructions: nil,
          feedback_id: entry.id,
          extra: %{"steer_run_id" => run.id}
        }

        # The fallback of a run as a squad leader runs as the squad too.
        if run.squad_id do
          SquadDispatch.enqueue_as(Origin.from_scope(scope), target, run.squad_id, trigger)
        else
          {:ok, outcome} = Runs.enqueue(Origin.from_scope(scope), target, trigger)
          outcome
        end
      end

    %{outcome | steer_run_id: run.id}
  end

  # Decision 3, step 5: R as read in this transaction.
  defp push(run, entry) do
    case Repo.one(from(r in Run, where: r.id == ^run.id, select: {r.status, r.daemon_id})) do
      {:running, daemon_id} when not is_nil(daemon_id) ->
        Repo.insert_all(RunSteer, [
          %{
            workspace_id: run.workspace_id,
            run_id: run.id,
            feedback_id: entry.id,
            sent_at: DateTime.utc_now()
          }
        ])

        Events.after_commit(
          Events.topic(:daemon, daemon_id),
          {:steer_run, run.id, entry.id, text(entry)}
        )

      _other ->
        :ok
    end
  end

  ## Text (decision 4)

  @doc """
  The text pushed into the CLI for `entry` (loaded with `Helmsman.Feedback.load/2`):
  who added which record of what kind, the record quoted, and what to do.
  """
  @spec text(Entry.t()) :: String.t()
  def text(%Entry{task_ident: ident} = entry) when is_binary(ident) do
    last =
      if entry.kind == :question,
        do: "It is a question for you: answer it with add_feedback (kind \"answer\").",
        else: "Take it into account in this run."

    reply = Replies.label(entry)
    relation = if reply == "", do: "", else: " (" <> reply <> ")"

    Enum.join(
      [
        "#{author(entry)} added #{Id.build(ident, entry.seq)} (#{entry.kind})#{relation} to #{ident} " <>
          "while you are working on it:",
        Prompt.blockquote(entry.content),
        last
      ],
      "\n"
    )
  end

  defp author(%Entry{author: %Actor{name: name}}), do: name
  defp author(_entry), do: "Someone"

  ## Acknowledging (decision 6)

  @doc """
  The daemon of `ctx` took the push of `feedback_id` into the CLI of
  `run_id`. Locks the daemon row, then the run row (not this daemon's:
  `:not_found`; not `running` or `cancelling`: `:wrong_state`), then
  records the receipt once; the first one notifies `task:<id>` with
  `{:steer_acked, %{feedback_id, run_id}}`. A receipt for a record that
  was never pushed to the run changes nothing.
  """
  @spec ack(Lifecycle.daemon_ctx(), pos_integer(), pos_integer()) ::
          :ok | {:error, Lifecycle.error()}
  def ack(ctx, run_id, feedback_id) do
    result =
      Tx.run(fn ->
        with {:ok, _daemon} <- Lifecycle.lock_daemon(ctx),
             {:ok, run} <- Lifecycle.lock_run(ctx, run_id),
             do: ack_locked(run, feedback_id)
      end)

    with {:ok, :ok} <- result, do: :ok
  end

  defp ack_locked(%Run{status: status}, _feedback_id) when status not in @ackable,
    do: {:error, :wrong_state}

  defp ack_locked(run, feedback_id) do
    query =
      from(s in RunSteer,
        where: s.run_id == ^run.id and s.feedback_id == ^feedback_id and is_nil(s.acked_at)
      )

    case Repo.update_all(query, set: [acked_at: DateTime.utc_now()]) do
      {1, _} ->
        if run.task_id,
          do:
            Events.after_commit(
              Events.topic(:task, run.task_id),
              {:steer_acked, %{feedback_id: feedback_id, run_id: run.id}}
            )

      {0, _} ->
        unless Repo.exists?(
                 from(s in RunSteer, where: s.run_id == ^run.id and s.feedback_id == ^feedback_id)
               ),
               do:
                 Logger.warning(
                   "steer_ack for feedback #{feedback_id} that was never pushed to run #{run.id}"
                 )
    end

    {:ok, :ok}
  end

  ## Pushing again (decision 8)

  @doc """
  The pushes to send again after the daemon of `ctx` joined, reporting
  `run_ids`: of its `running` runs among them, the pushes without a
  receipt, by `sent_at`. `[{run_id, feedback_id, text}]`.
  """
  @spec unacked(Lifecycle.daemon_ctx(), [pos_integer()]) ::
          [{pos_integer(), pos_integer(), String.t()}]
  def unacked(_ctx, []), do: []

  def unacked(ctx, run_ids) do
    rows =
      Repo.all(
        from(s in RunSteer,
          join: r in Run,
          on: r.id == s.run_id,
          join: f in Entry,
          on: f.id == s.feedback_id,
          join: t in Task,
          on: t.id == f.task_id,
          where:
            s.run_id in ^run_ids and r.daemon_id == ^ctx.daemon_id and r.status == :running and
              is_nil(s.acked_at),
          order_by: [asc: s.sent_at, asc: s.run_id, asc: s.feedback_id],
          select: {s.run_id, f, t.ident}
        )
      )

    for {run_id, entry, ident} <- rows do
      [entry] = Feedback.load(entry, ident)
      {run_id, entry.id, text(entry)}
    end
  end

  ## Settling (decision 7)

  @doc """
  The facts settling needs for `triggers`: for each `(steer_run_id,
  feedback_id)` they carry that was pushed, the pushed run's status and
  the receipt time. One query (none without such triggers). Read without
  locks: see decision 7 for why they cannot change under the reader.
  """
  @spec facts([map()]) :: facts()
  def facts(triggers) when is_list(triggers) do
    pairs =
      for %{"steer_run_id" => s, "feedback_id" => f} <- triggers,
          is_integer(s) and is_integer(f),
          uniq: true,
          do: {s, f}

    case pairs do
      [] ->
        %{}

      pairs ->
        run_ids = pairs |> Enum.map(&elem(&1, 0)) |> Enum.uniq()
        feedback_ids = pairs |> Enum.map(&elem(&1, 1)) |> Enum.uniq()

        from(s in RunSteer,
          join: r in Run,
          on: r.id == s.run_id,
          where: s.run_id in ^run_ids and s.feedback_id in ^feedback_ids,
          select: {s.run_id, s.feedback_id, r.status, s.acked_at}
        )
        |> Repo.all()
        |> Enum.filter(fn {s, f, _status, _acked} -> {s, f} in pairs end)
        |> Map.new(fn {s, f, status, acked} -> {{s, f}, %{status: status, acked_at: acked}} end)
    end
  end

  @doc """
  Whether `trigger` is settled (decision 7): it waits for a run S
  (`steer_run_id`) that `succeeded` and acknowledged the push of its
  `feedback_id`. Pure.
  """
  @spec settled?(map(), facts()) :: boolean()
  def settled?(%{"steer_run_id" => s, "feedback_id" => f}, facts)
      when is_integer(s) and is_integer(f) do
    match?(%{status: :succeeded, acked_at: %DateTime{}}, Map.get(facts, {s, f}))
  end

  def settled?(_trigger, _facts), do: false

  @doc """
  Removes the settled triggers of `run` (pure): `:unchanged`;
  `{:obsolete, steer_run_ids}` when nothing but neutral markers is left;
  otherwise `{:pruned, changes}` with the triggers left, the authorization
  source and causal chain recomputed from them (`Revalidation.derive/2`).
  """
  @spec prune(Run.t(), facts()) ::
          :unchanged | {:obsolete, [pos_integer()]} | {:pruned, map()}
  def prune(%Run{triggers: triggers} = run, facts) do
    {settled, kept} = Enum.split_with(triggers, &settled?(&1, facts))

    cond do
      settled == [] ->
        :unchanged

      Enum.all?(kept, &Triggers.neutral?/1) ->
        {:obsolete, settled |> Enum.map(& &1["steer_run_id"]) |> Enum.uniq() |> Enum.sort()}

      true ->
        {:pruned, Revalidation.derive(run, kept)}
    end
  end

  @doc "The error text of a fallback run cancelled because it was settled."
  @spec obsolete_error([pos_integer()]) :: String.t()
  def obsolete_error(run_ids), do: "steering delivered to run #{Enum.join(run_ids, ", ")}"

  @doc """
  The `steer_settle` side effect of the run `run_id` (decision 7): when it
  `succeeded`, the settled triggers are removed from the `deferred` and
  `queued` runs of its task and agent whose triggers refer to it
  (decisions 7, 15); a run left with nothing but
  neutral markers is `cancelled` (`obsolete`). Returns how many runs
  changed.

  Each candidate is settled in a transaction of its own that locks only
  its run row `FOR UPDATE` and checks it again under that lock: holding
  one run row at a time, it never waits in a cycle with writes that lock
  pending runs of several lanes in another order (a feedback record that
  answers in the `work` lane and mentions in `reply`). So it must not run
  inside a transaction.
  """
  @spec settle(pos_integer()) :: {:ok, non_neg_integer()}
  def settle(run_id) do
    if Repo.in_transaction?(),
      do: raise("Helmsman.Runs.Steering.settle/1 must not run in a transaction")

    case Repo.get(Run, run_id) do
      %Run{status: :succeeded, task_id: task_id, agent_id: agent_id}
      when not is_nil(task_id) ->
        ids =
          Repo.all(
            from(r in Run,
              where:
                r.task_id == ^task_id and r.agent_id == ^agent_id and
                  r.status in ^Run.pending_statuses() and
                  fragment("? @> ?", r.triggers, ^[%{"steer_run_id" => run_id}]),
              order_by: r.id,
              select: r.id
            )
          )

        {:ok, Enum.count(ids, &settle_one/1)}

      _other ->
        {:ok, 0}
    end
  end

  defp settle_one(id) do
    {:ok, changed?} =
      Tx.run(fn ->
        query =
          from(r in Run,
            where: r.id == ^id and r.status in ^Run.pending_statuses(),
            lock: "FOR UPDATE"
          )

        case Repo.one(query) do
          nil -> {:ok, false}
          run -> {:ok, settle_pending(run)}
        end
      end)

    changed?
  end

  defp settle_pending(run) do
    case prune(run, facts(run.triggers)) do
      :unchanged ->
        false

      {:obsolete, run_ids} ->
        Lifecycle.end!(run, :cancelled, failure_reason: :obsolete, error: obsolete_error(run_ids))
        true

      {:pruned, changes} ->
        Lifecycle.update!(run, Map.to_list(changes))
        true
    end
  end

  @doc """
  Whether `run` (ended `succeeded`) has an acknowledged push, so that its
  `steer_settle` side effect is due.
  """
  @spec acked?(Run.t()) :: boolean()
  def acked?(%Run{id: id}),
    do: Repo.exists?(from(s in RunSteer, where: s.run_id == ^id and not is_nil(s.acked_at)))

  ## Reading (decision 10)

  @doc """
  The run of the task `ident` that `scope` may steer (`:read_tasks`): its
  `running` run (nil: none) with the agent's name, whether its CLI takes
  input live (`live_providers/0`), and whether `scope` may steer it
  (`allowed`; else `reason`: `:not_a_person`, `:forbidden`, or the reason
  of `Helmsman.Agents.trigger_check/3`).
  """
  @spec steerable(Scope.t(), String.t()) ::
          {:ok, steerable() | nil} | {:error, :forbidden | :not_found}
  def steerable(%Scope{workspace: %Workspace{id: workspace_id}} = scope, ident)
      when is_binary(ident) do
    with :ok <- Policy.authorize(scope, :read_tasks),
         {:ok, ident, _key, _seq} <- Ident.parse(ident),
         %Task{} = task <-
           Repo.one(from(t in Task, where: t.workspace_id == ^workspace_id and t.ident == ^ident)) do
      query =
        from(r in Run,
          join: a in Actor,
          on: a.id == r.agent_id,
          left_join: p in AgentProfile,
          on: p.actor_id == a.id,
          where: r.task_id == ^task.id and r.status == :running,
          order_by: r.id,
          limit: 1,
          select: {r.id, a, p.provider}
        )

      case Repo.one(query) do
        nil ->
          {:ok, nil}

        {run_id, agent, provider} ->
          reason = refused(scope, agent)

          {:ok,
           %{
             run_id: run_id,
             agent: agent.name,
             live: provider in Enum.map(@live_providers, &Atom.to_string/1),
             allowed: is_nil(reason),
             reason: reason
           }}
      end
    else
      nil -> {:error, :not_found}
      error -> error
    end
  end

  defp refused(%Scope{actor: %Actor{kind: :human}} = scope, agent) do
    with :ok <- Policy.authorize(scope, :add_feedback),
         :ok <- Agents.trigger_check(agent.workspace_id, scope.user.id, agent) do
      nil
    else
      {:error, :not_managed} -> :unauthorized
      {:error, reason} -> reason
    end
  end

  defp refused(_scope, _agent), do: :not_a_person

  @doc """
  The steering state of each of `feedback_ids` that was pushed: one query.
  """
  @spec views([pos_integer()]) :: %{pos_integer() => view()}
  def views([]), do: %{}

  def views(feedback_ids) do
    from(s in RunSteer,
      join: r in Run,
      on: r.id == s.run_id,
      join: a in Actor,
      on: a.id == r.agent_id,
      where: s.feedback_id in ^feedback_ids,
      select:
        {s.feedback_id,
         %{run_id: s.run_id, agent: a.name, sent_at: s.sent_at, acked_at: s.acked_at}}
    )
    |> Repo.all()
    |> Map.new()
  end
end
