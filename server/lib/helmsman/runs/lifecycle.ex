defmodule Helmsman.Runs.Lifecycle do
  @moduledoc """
  What a daemon reports about the runs it claimed (designs/13 §4,
  `add-run-lifecycle` decisions 2, 5–8, 13, 23, 24): starting, started,
  execution events, the end, and reconciliation on heartbeats and joins.

  Every report runs in its own transaction that locks the daemon row
  `FOR SHARE` (revoked or another authorization epoch:
  `{:error, :reauthorized}`) and then the run row `FOR UPDATE` (not
  claimed by this daemon: `{:error, :not_found}`; a status the report
  does not accept: `{:error, :wrong_state}`). Only `starting` locks more,
  before the daemon row (decision 24). Effects on the task go to Oban jobs
  inserted in the same transaction (decisions 12, 25).
  """

  import Ecto.Query, warn: false

  alias Helmsman.Actors.Actor
  alias Helmsman.AgentDesigns
  alias Helmsman.Agents.AgentProfile
  alias Helmsman.Daemons
  alias Helmsman.Daemons.{Daemon, Locking, Runtime}
  alias Helmsman.Events
  alias Helmsman.Repo
  alias Helmsman.Runs
  alias Helmsman.Runs.{Revalidation, Run, RunEvent, RunTokens, Steering}
  alias Helmsman.Runs.Workers.{Retry, SideEffect}
  alias Helmsman.Squads.Dispatch, as: SquadDispatch
  alias Helmsman.Tasks.Task
  alias Helmsman.Tx
  alias Helmsman.Workspaces.Membership
  alias HelmsmanProtocol.{Event, Report}

  @heartbeat_grace_seconds 60
  @member_roles [:owner, :admin, :member]

  # `protocol`: the version the connection negotiated; claiming without it
  # is as an old daemon (`add-provider-accounts` decision 4).
  @type daemon_ctx :: %{
          required(:daemon_id) => pos_integer(),
          required(:user_id) => pos_integer(),
          required(:auth_epoch) => pos_integer(),
          optional(:protocol) => pos_integer()
        }
  @type error :: :not_found | :wrong_state | :reauthorized | {:invalid_payload, term()}

  ## Locks shared by every report

  @doc false
  @spec lock_daemon(daemon_ctx()) :: {:ok, Daemon.t()} | {:error, :reauthorized}
  def lock_daemon(%{daemon_id: id, auth_epoch: epoch}) do
    daemon = Repo.one(from(d in Daemon, where: d.id == ^id, lock: "FOR SHARE"))

    case Daemons.authorized(daemon, epoch) do
      :ok -> {:ok, daemon}
      _error -> {:error, :reauthorized}
    end
  end

  @doc false
  # The run row `FOR UPDATE` (`:share`: `FOR SHARE`), when this daemon
  # claimed it.
  @spec lock_run(daemon_ctx(), pos_integer(), :update | :share) ::
          {:ok, Run.t()} | {:error, :not_found}
  def lock_run(%{daemon_id: daemon_id}, run_id, mode \\ :update) do
    query =
      case mode do
        :update -> from(r in Run, where: r.id == ^run_id, lock: "FOR UPDATE")
        :share -> from(r in Run, where: r.id == ^run_id, lock: "FOR SHARE")
      end

    case Repo.one(query) do
      %Run{daemon_id: ^daemon_id} = run -> {:ok, run}
      _other -> {:error, :not_found}
    end
  end

  defp locked(ctx, run_id, fun) do
    Tx.run(fn ->
      with {:ok, _daemon} <- lock_daemon(ctx),
           {:ok, run} <- lock_run(ctx, run_id),
           do: fun.(run)
    end)
  end

  ## Changing a run

  @doc false
  # Updates the locked run and registers its notification.
  @spec update!(Run.t(), keyword()) :: Run.t()
  def update!(%Run{id: id}, changes) do
    {1, [run]} =
      Repo.update_all(
        from(r in Run, where: r.id == ^id, select: r),
        set: Keyword.put(changes, :updated_at, DateTime.utc_now())
      )

    Runs.notify_run(run)
    run
  end

  @doc false
  # Ends the locked run: `status` with `changes`, `finished_at`, then its
  # token revoked (run row, then token row: decision 27). A run that was
  # claimed, running or cancelling wakes its task's pull request
  # reconciliation (`Helmsman.Runs.after_terminal/1`).
  @spec end!(Run.t(), Run.status(), keyword()) :: Run.t()
  def end!(%Run{} = run, status, changes \\ []) do
    active? = run.status in Run.active_statuses()
    run = update!(run, [status: status, finished_at: DateTime.utc_now()] ++ changes)
    RunTokens.revoke(run.id)
    if active?, do: Runs.after_terminal(run)
    Runs.after_ended([run])
    run
  end

  @doc false
  # Inserts the automatic retry job of a failed run (decision 25) when its
  # reason is retryable and its limit not reached; the job decides again.
  @spec maybe_retry(Run.t()) :: :ok
  def maybe_retry(%Run{status: :failed} = run) do
    if Runs.Retry.automatic?(run), do: {:ok, _job} = Oban.insert(Retry.new(%{run_id: run.id}))
    :ok
  end

  def maybe_retry(_run), do: :ok

  ## starting

  @doc """
  The daemon is about to start the CLI of `run_id` (decisions 5, 23, 24).

  First time: a `claimed` run is checked again (`Revalidation`); valid →
  `running`, `started_at`, an `auto_claim` job, `:proceed`; invalid →
  `failed` (`obsolete` / `unauthorized`), `{:abort, reason}`. A
  `cancelling` run → `cancelled`, `{:abort, "cancelled"}`.

  Replays give the first decision: `running` with `started_at` →
  `:proceed` without any change; ended without `started_at` → `{:abort,
  reason}`. Anything else is `:wrong_state`.

  Every row the check reads is locked first, in the global order
  (memberships by ID, actor, the squads' identity and `squads` rows,
  profile, daemon, task, runtime, run).
  """
  @spec starting(daemon_ctx(), pos_integer()) ::
          {:ok, :proceed | {:abort, String.t()}} | {:error, error()}
  def starting(ctx, run_id) do
    Tx.run(fn ->
      case Repo.get(Run, run_id) do
        %Run{daemon_id: daemon_id} = run when daemon_id == ctx.daemon_id ->
          starting_locked(ctx, run)

        _other ->
          {:error, :not_found}
      end
    end)
  end

  defp starting_locked(ctx, snapshot) do
    members = lock_members(snapshot, ctx.user_id)
    agent = Repo.one!(from(a in Actor, where: a.id == ^snapshot.agent_id, lock: "FOR SHARE"))
    {:ok, squads} = SquadDispatch.lock_for_check(snapshot, :wait)

    profile =
      Repo.one(from(p in AgentProfile, where: p.actor_id == ^agent.id, lock: "FOR SHARE"))

    with {:ok, _daemon} <- lock_daemon(ctx) do
      task =
        snapshot.task_id &&
          Repo.one!(from(t in Task, where: t.id == ^snapshot.task_id, lock: "FOR SHARE"))

      runtime =
        Repo.one(from(r in Runtime, where: r.id == ^snapshot.runtime_id, lock: "FOR SHARE"))

      Locking.hook(:starting_locked)

      with {:ok, run} <- lock_run(ctx, snapshot.id) do
        locked = %{
          members: members,
          agent: agent,
          squads: squads,
          profile: profile,
          task: task,
          runtime: runtime,
          steers: Steering.facts(run.triggers),
          design: AgentDesigns.turn_state(run),
          autopilot: Helmsman.Autopilots.record_state(run)
        }

        decide_starting(run, locked, ctx.user_id)
      end
    end
  end

  # Ordered by membership ID, as `Helmsman.Members` locks them FOR UPDATE.
  defp lock_members(run, daemon_user_id) do
    Repo.all(
      from(m in Membership,
        where:
          m.workspace_id == ^run.workspace_id and m.user_id in ^user_ids(run, daemon_user_id),
        order_by: m.id,
        lock: "FOR SHARE",
        select: {m.user_id, m.role}
      )
    )
    |> Map.new()
  end

  @doc false
  # The users whose membership a check reads: every authorization source of
  # the run and the daemon's user.
  @spec user_ids(Run.t(), pos_integer()) :: [pos_integer()]
  def user_ids(run, daemon_user_id) do
    run.triggers
    |> Enum.map(& &1["initiator_user_id"])
    |> Enum.filter(&is_integer/1)
    |> Enum.concat([run.root_initiator_user_id, daemon_user_id])
    |> Enum.uniq()
  end

  defp decide_starting(%Run{status: :cancelling} = run, _locked, _user_id) do
    end!(run, :cancelled)
    {:ok, {:abort, "cancelled"}}
  end

  defp decide_starting(%Run{status: :claimed} = run, locked, daemon_user_id) do
    case check(run, locked, daemon_user_id) do
      :ok ->
        start!(run, [])

      {:pruned, changes} ->
        start!(run, Map.to_list(changes))

      {:obsolete, why} ->
        end!(run, :failed, [failure_reason: :obsolete] ++ obsolete_error(run, why, locked))
        {:ok, {:abort, "obsolete"}}

      :unauthorized ->
        end!(run, :failed, failure_reason: :unauthorized)
        {:ok, {:abort, "unauthorized"}}
    end
  end

  defp decide_starting(%Run{status: :running, started_at: %DateTime{}}, _locked, _user_id),
    do: {:ok, :proceed}

  defp decide_starting(%Run{status: status, started_at: nil} = run, _locked, _user_id)
       when status in [:succeeded, :failed, :cancelled],
       do: {:ok, {:abort, abort_reason(run)}}

  defp decide_starting(_run, _locked, _user_id), do: {:error, :wrong_state}

  @doc false
  # The error text of a run made obsolete by steering (`add-run-steering`
  # decision 7), as a keyword list of changes.
  @spec obsolete_error(Run.t(), Revalidation.obsolete_why(), Revalidation.locked()) :: keyword()
  def obsolete_error(run, :steered, locked) do
    case Steering.prune(run, Map.get(locked, :steers, %{})) do
      {:obsolete, run_ids} -> [error: Steering.obsolete_error(run_ids)]
      _other -> []
    end
  end

  def obsolete_error(_run, _why, _locked), do: []

  defp abort_reason(%Run{status: :cancelled}), do: "cancelled"
  defp abort_reason(%Run{failure_reason: nil}), do: "cancelled"
  defp abort_reason(%Run{failure_reason: reason}), do: Atom.to_string(reason)

  @doc false
  # `Revalidation.check/2`, and the daemon's user must still serve the
  # workspace (member or above).
  @spec check(Run.t(), Revalidation.locked(), pos_integer()) :: Revalidation.result()
  def check(run, locked, daemon_user_id) do
    if Map.get(locked.members, daemon_user_id) in @member_roles,
      do: Revalidation.check(run, locked),
      else: {:obsolete, :not_served}
  end

  defp start!(run, changes) do
    run = update!(run, [status: :running, started_at: DateTime.utc_now()] ++ changes)

    if run.task_id,
      do: {:ok, _job} = Oban.insert(SideEffect.new(%{run_id: run.id, kind: "auto_claim"}))

    {:ok, :proceed}
  end

  ## started

  @doc """
  The CLI has started (decision 6): accepted for a `running` or `cancelling`
  run. Idempotent. The report's session is only a resume candidate and is
  ignored (`update-codex-user-home` decision 7); events and the finished
  report record sessions confirmed by the CLI.
  """
  @spec started(daemon_ctx(), Report.Started.t()) :: :ok | {:error, error()}
  def started(ctx, %Report.Started{run_id: run_id}) do
    result =
      locked(ctx, run_id, fn
        %Run{status: status} when status in [:running, :cancelling] ->
          {:ok, :ok}

        _run ->
          {:error, :wrong_state}
      end)

    with {:ok, :ok} <- result, do: :ok
  end

  ## events

  @doc """
  Saves execution events (decision 7): a `running` or `cancelling` run
  ignores the sequence numbers it has; the others must follow its last one
  without a gap (`{:invalid_payload, :gap}`, nothing saved). A `session`
  event records the session. Returns the last saved sequence number;
  `run:<id>` gets `{:run_events, run_id, [event_view]}` with the new
  events after the commit.
  """
  @spec append_events(daemon_ctx(), pos_integer(), [Event.t()]) ::
          {:ok, non_neg_integer()} | {:error, error()}
  def append_events(ctx, run_id, events) when is_list(events) do
    locked(ctx, run_id, fn
      %Run{status: status} = run when status in [:running, :cancelling] ->
        events |> Enum.filter(&(&1.seq > run.events_seq)) |> save_events(run)

      _run ->
        {:error, :wrong_state}
    end)
  end

  defp save_events([], run), do: {:ok, run.events_seq}

  defp save_events(events, run) do
    if contiguous?(events, run.events_seq) do
      rows = Enum.map(events, &event_row(run.id, &1))
      Repo.insert_all(RunEvent, rows, on_conflict: :nothing)
      last = List.last(rows)

      session =
        rows
        |> Enum.filter(&(&1.type == "session"))
        |> Enum.map(& &1.data["session_id"])
        |> Enum.reject(&(&1 in [nil, ""]))
        |> List.last()

      run =
        update!(
          run,
          [events_seq: last.seq, last_event_at: DateTime.utc_now()] ++
            if(session, do: [session_id: session], else: [])
        )

      views = Enum.map(rows, &Runs.event_view/1)
      Events.after_commit(Events.topic(:run, run.id), {:run_events, run.id, views})
      {:ok, run.events_seq}
    else
      {:error, {:invalid_payload, :gap}}
    end
  end

  defp contiguous?(events, last_seq) do
    events
    |> Enum.with_index(last_seq + 1)
    |> Enum.all?(fn {event, expected} -> event.seq == expected end)
  end

  defp event_row(run_id, %Event{} = event) do
    wire = Event.to_wire(event)

    %{
      run_id: run_id,
      seq: event.seq,
      type: Atom.to_string(event.type),
      data: wire["data"],
      at: usec(event.at)
    }
  end

  defp usec(%DateTime{microsecond: {us, _precision}} = at), do: %{at | microsecond: {us, 6}}

  ## finished

  @doc """
  The run has ended (decision 13). Accepted for `claimed` (failed while
  preparing), `running` and `cancelling` runs; a `cancelling` run is
  `cancelled` whatever was reported, keeping its failure reason. Records
  the summary, usage, error and session (`push_failed` without a push
  record: `push_status = failed`), revokes the token, and inserts
  the `fallback` job (`succeeded` with a task), the `steer_settle` job
  (`succeeded` with an acknowledged steering push, `add-run-steering`
  decision 7) or the automatic retry job (decision 25). The same end reported again is `:ok`; another end is
  `:wrong_state`.
  """
  @spec finish(daemon_ctx(), Report.Finished.t()) :: :ok | {:error, error()}
  def finish(ctx, %Report.Finished{run_id: run_id} = report) do
    result =
      locked(ctx, run_id, fn
        %Run{status: status} = run when status in [:claimed, :running, :cancelling] ->
          finish_locked(run, report)

        %Run{status: status} when status == report.status ->
          {:ok, :ok}

        _run ->
          {:error, :wrong_state}
      end)

    with {:ok, :ok} <- result, do: :ok
  end

  defp finish_locked(run, report) do
    {status, reason} =
      if run.status == :cancelling,
        do: {:cancelled, run.failure_reason},
        else: {report.status, report.failure_reason}

    run =
      end!(
        run,
        status,
        [
          failure_reason: reason,
          summary: report.summary,
          usage: report.usage && Event.Usage.to_wire(report.usage),
          error: report.error
        ] ++
          if(report.session_id in [nil, ""], do: [], else: [session_id: report.session_id]) ++
          push_failed(run, reason)
      )

    if run.status == :succeeded and run.task_id,
      do: {:ok, _job} = Oban.insert(SideEffect.new(%{run_id: run.id, kind: "fallback"}))

    # `add-run-steering` decision 7: settle the triggers waiting for it.
    if (run.status == :succeeded and run.task_id) && Steering.acked?(run),
      do: {:ok, _job} = Oban.insert(SideEffect.new(%{run_id: run.id, kind: "steer_settle"}))

    maybe_retry(run)
    {:ok, :ok}
  end

  # `add-daemon-git-workspace` decision 6: a push record, if any, stays.
  defp push_failed(%Run{pushed_at: nil}, :push_failed), do: [push_status: :failed]
  defp push_failed(_run, _reason), do: []

  ## Reconciliation

  @doc """
  Reconciles the runs a daemon reports as executing (decision 8), on a
  heartbeat (`:heartbeat`) or a join (`:join`):

    * `terminate_run_ids`: the reported runs that are not this daemon's or
      no longer `claimed`, `running` or `cancelling`;
    * this daemon's runs in those statuses that it did not report — on a
      heartbeat only when claimed over #{@heartbeat_grace_seconds} seconds ago —
      end, each in its own transaction: `failed` (`daemon_restart`, then
      the automatic retry job), a `cancelling` one `cancelled`;
    * `cancel_run_ids`: the reported runs still `cancelling`, whose
      `cancel` the caller pushes again.
  """
  @spec reconcile(daemon_ctx(), [pos_integer()], :heartbeat | :join) ::
          {:ok, %{terminate_run_ids: [pos_integer()], cancel_run_ids: [pos_integer()]}}
  def reconcile(ctx, reported_ids, mode) when mode in [:heartbeat, :join] do
    reported_ids = Enum.uniq(reported_ids)

    known =
      Repo.all(
        from(r in Run,
          where: r.id in ^reported_ids,
          select: {r.id, r.daemon_id, r.status}
        )
      )

    own_active =
      for {id, daemon_id, status} <- known,
          daemon_id == ctx.daemon_id and status in Run.active_statuses(),
          do: {id, status}

    terminate = reported_ids -- Enum.map(own_active, &elem(&1, 0))
    cancel = for {id, :cancelling} <- own_active, do: id

    ctx
    |> unreported(reported_ids, mode)
    |> Enum.each(&reap(ctx, &1, reported_ids, mode))

    {:ok, %{terminate_run_ids: terminate, cancel_run_ids: cancel}}
  end

  defp unreported(ctx, reported_ids, mode) do
    query =
      from(r in Run,
        where:
          r.daemon_id == ^ctx.daemon_id and r.status in ^Run.active_statuses() and
            r.id not in ^reported_ids,
        order_by: r.id,
        select: r.id
      )

    query
    |> grace(mode)
    |> Repo.all()
  end

  defp grace(query, :join), do: query

  defp grace(query, :heartbeat),
    do: where(query, [r], r.claimed_at < ^grace_cutoff())

  defp grace_cutoff, do: DateTime.add(DateTime.utc_now(), -@heartbeat_grace_seconds, :second)

  defp reap(ctx, run_id, reported_ids, mode) do
    locked(ctx, run_id, fn run ->
      if reapable?(run, reported_ids, mode), do: reap!(run)
      {:ok, :ok}
    end)
  end

  defp reapable?(run, reported_ids, mode) do
    run.status in Run.active_statuses() and run.id not in reported_ids and
      (mode == :join or DateTime.compare(run.claimed_at, grace_cutoff()) == :lt)
  end

  defp reap!(%Run{status: :cancelling} = run), do: end!(run, :cancelled)

  defp reap!(run) do
    run |> end!(:failed, failure_reason: :daemon_restart) |> maybe_retry()
  end
end
