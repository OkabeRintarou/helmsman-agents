defmodule Helmsman.Runs.Retry do
  @moduledoc """
  Retries (designs/13 §5, `add-run-lifecycle` decisions 14, 25).

  Automatic: a `failed` run whose reason is retryable and whose limit is
  not reached gets a `Helmsman.Runs.Workers.Retry` job in the transaction
  that ended it; the job requeues it (`perform/1`) after locking, in the
  global order, the workspace maintenance lock (shared), the agent's actor
  and profile rows, the task row and the agent's current runtime row
  `FOR SHARE`, and the failed run. Manual: `retry/2`.

  A retry carries the failed run's triggers (without older retry markers)
  and a marker `%{"kind" => "retry", "retry_of" => id, "auto" => bool,
  "by_actor_id", "at"}`, keeps its authorization source, causal chain,
  priority, lane and task, and goes to the agent's current runtime. It
  merges into the queued run of the same `(task, agent, lane, squad)` if
  there is one (`Helmsman.Runs.upsert_pending/2`). It is checked again when claimed.
  """

  import Ecto.Query, warn: false

  alias Helmsman.Accounts.Scope
  alias Helmsman.Actors.Actor
  alias Helmsman.Agents.AgentProfile
  alias Helmsman.Daemons.{Locking, Runtime}
  alias Helmsman.Locks
  alias Helmsman.Policy
  alias Helmsman.Repo
  alias Helmsman.Runs
  alias Helmsman.Runs.{Run, Stop}
  alias Helmsman.Tasks.Task
  alias Helmsman.Tx
  alias Helmsman.Workspaces

  # reason => {limit, delay in seconds}; lease_expired is not counted.
  @automatic %{
    runtime_offline: {2, 0},
    daemon_restart: {2, 0},
    timeout: {2, 0},
    stalled: {2, 0},
    push_conflict: {2, 0},
    push_failed: {2, 0},
    provider_network: {3, 30},
    provider_rate_limit: {1, 300}
  }

  @doc """
  Whether the failed `run` is retried automatically (decision 14). A
  design run never is (`add-agent-conversation` decision 10), nor a
  run-only autopilot run (`add-autopilots` decision 11).
  """
  @spec automatic?(Run.t()) :: boolean()
  def automatic?(%Run{} = run),
    do: not Runs.design_run?(run) and not Runs.autopilot_run?(run) and retryable?(run)

  defp retryable?(%Run{status: :failed, failure_reason: :lease_expired}), do: true

  defp retryable?(%Run{status: :failed, failure_reason: reason, auto_retries: retries}) do
    case Map.fetch(@automatic, reason) do
      {:ok, {limit, _delay}} -> retries < limit
      :error -> false
    end
  end

  defp retryable?(_run), do: false

  ## Automatic

  @doc """
  The automatic retry of the failed run `run_id` (decision 25): nothing
  when it was retried already, when it is not retryable, when the agent is
  disabled, archived or unbound, its runtime disabled or a `work` run's
  task closed. Returns `{:ok, :retried | :skipped}`.
  """
  @spec perform(pos_integer()) :: {:ok, :retried | :skipped}
  def perform(run_id) do
    Tx.run(fn ->
      case Repo.get(Run, run_id) do
        nil -> {:ok, :skipped}
        snapshot -> perform_locked(snapshot)
      end
    end)
  end

  defp perform_locked(snapshot) do
    Locks.maint_shared!(snapshot.workspace_id)
    agent = Repo.one!(from(a in Actor, where: a.id == ^snapshot.agent_id, lock: "FOR SHARE"))

    profile =
      Repo.one(from(p in AgentProfile, where: p.actor_id == ^agent.id, lock: "FOR SHARE"))

    task =
      snapshot.task_id &&
        Repo.one!(from(t in Task, where: t.id == ^snapshot.task_id, lock: "FOR SHARE"))

    runtime =
      profile && profile.runtime_id &&
        Repo.one(from(r in Runtime, where: r.id == ^profile.runtime_id, lock: "FOR SHARE"))

    Locking.hook(:retry_locked)
    run = lock_original(snapshot)

    cond do
      not automatic?(run) -> {:ok, :skipped}
      retried?(run) != nil -> {:ok, :skipped}
      unavailable(agent, profile, runtime, run, task) != nil -> not_requeued(run)
      true -> requeue(run, auto: true, runtime_id: runtime.id) |> retried(run)
    end
  end

  defp retried({:ok, _run}, _original), do: {:ok, :retried}
  defp retried({:error, _reason}, original), do: not_requeued(original)

  # `add-squads` decision 9: a delegated run whose automatic retry did not
  # happen wakes its leader now.
  defp not_requeued(run) do
    if Runs.delegated?(run), do: Runs.delegate_done!(run)
    # `add-spec-workflow` decision 10: its review requests lapse now.
    if Runs.spec_requests?(run), do: Runs.spec_settle!(run)
    # `add-autopilots` decision 8: the autopilot that started its task
    # settles now.
    Helmsman.Autopilots.after_task_changed(run.task_id)
    {:ok, :skipped}
  end

  defp unavailable(agent, profile, runtime, run, task),
    do: agent_unavailable(agent, profile) || runtime_unavailable(runtime) || closed(run, task)

  defp agent_unavailable(agent, profile) do
    cond do
      not is_nil(agent.disabled_at) -> :agent_disabled
      is_nil(profile) or not is_nil(profile.archived_at) -> :agent_archived
      true -> nil
    end
  end

  defp runtime_unavailable(nil), do: :no_runtime
  defp runtime_unavailable(%Runtime{disabled_at: nil}), do: nil
  defp runtime_unavailable(%Runtime{}), do: :runtime_disabled

  defp closed(%Run{lane: :work}, %Task{status: status}) when status in [:verified, :cancelled],
    do: :task_closed

  defp closed(_run, _task), do: nil

  # Last of the locks (designs/01 §4), FOR UPDATE: every retry of the same
  # run, automatic or manual, with or without a task, waits here, so only
  # one of them finds it not retried yet.
  defp lock_original(snapshot) do
    run = Repo.one!(from(r in Run, where: r.id == ^snapshot.id, lock: "FOR UPDATE"))
    Locking.hook(:retry_checking)
    run
  end

  defp retried?(run) do
    case targets([run])[run.id] do
      nil -> nil
      id -> Repo.get!(Run, id)
    end
  end

  @retry_markers """
  SELECT (t->>'retry_of')::bigint, r.id
    FROM runs r, jsonb_array_elements(r.triggers) t
   WHERE r.task_id = ANY($2) AND r.agent_id = ANY($3)
     AND t->>'kind' = 'retry' AND (t->>'retry_of')::bigint = ANY($1)
  """

  @doc """
  The run that retries each of `runs`, in two queries: `%{run_id =>
  retry_id}` (absent: not retried). A retry is the run whose `retry_of_id`
  is it, or a run whose triggers carry its retry marker (it was merged into
  a queued run); the earliest when there are several. Only runs with a task
  are merged, so markers are looked for among the runs of the same tasks
  and agents.
  """
  @spec targets([Run.t()]) :: %{pos_integer() => pos_integer()}
  def targets([]), do: %{}

  def targets(runs) do
    ids = Enum.map(runs, & &1.id)
    agent_ids = runs |> Enum.map(& &1.agent_id) |> Enum.uniq()
    task_ids = runs |> Enum.map(& &1.task_id) |> Enum.reject(&is_nil/1) |> Enum.uniq()

    direct =
      Repo.all(from(r in Run, where: r.retry_of_id in ^ids, select: {r.retry_of_id, r.id}))

    merged =
      if task_ids == [],
        do: [],
        else: Repo.query!(@retry_markers, [ids, task_ids, agent_ids]).rows

    direct
    |> Enum.concat(Enum.map(merged, &List.to_tuple/1))
    |> Enum.reduce(%{}, fn {original, target}, acc ->
      Map.update(acc, original, target, &min(&1, target))
    end)
  end

  @doc """
  Requeues the failed or cancelled `run` (decision 14) in the caller's
  transaction, which holds the locks of decision 25 (automatic) or those
  of `retry/2`. Options: `auto` (boolean), `by_actor_id`, `runtime_id`
  (the agent's current runtime). Returns the queued run.
  """
  @spec requeue(Run.t(), keyword()) :: {:ok, Run.t()} | {:error, :rate_limited}
  def requeue(%Run{} = run, opts) do
    auto? = Keyword.fetch!(opts, :auto)
    lease? = auto? and run.failure_reason == :lease_expired

    marker = %{
      "kind" => "retry",
      "retry_of" => run.id,
      "auto" => auto?,
      "by_actor_id" => opts[:by_actor_id],
      "at" => DateTime.to_iso8601(DateTime.utc_now())
    }

    attrs = %{
      workspace_id: run.workspace_id,
      agent_id: run.agent_id,
      runtime_id: Keyword.fetch!(opts, :runtime_id),
      task_id: run.task_id,
      lane: run.lane,
      triggers: Enum.reject(run.triggers, &(&1["kind"] == "retry")) ++ [marker],
      root_initiator_user_id: run.root_initiator_user_id,
      causal_agent_ids: run.causal_agent_ids,
      capabilities: run.capabilities,
      priority: run.priority,
      attempt: if(lease?, do: run.attempt, else: run.attempt + 1),
      auto_retries: auto_retries(run, auto?, lease?),
      retry_of_id: run.id,
      not_before: not_before(run, auto?),
      # A retry runs as the same squad, if any (`add-squads` decision 6).
      squad_id: run.squad_id
    }

    case Runs.upsert_pending(attrs, rate_limit?: not auto?) do
      {:skipped, reason} -> {:error, reason}
      {_queued_or_merged, run} -> {:ok, run}
    end
  end

  defp auto_retries(_run, false, _lease?), do: 0
  defp auto_retries(run, true, true), do: run.auto_retries
  defp auto_retries(run, true, false), do: run.auto_retries + 1

  defp not_before(run, true) do
    case Map.get(@automatic, run.failure_reason) do
      {_limit, delay} when delay > 0 -> DateTime.add(DateTime.utc_now(), delay, :second)
      _none -> nil
    end
  end

  defp not_before(_run, false), do: nil

  ## Manual

  @doc """
  Retries the `failed` or `cancelled` run `run_id` by hand (`:retry_run`,
  decision 14), without a limit on the number. Errors: `:not_found`,
  `:forbidden`, `:not_ended` (not `failed` or `cancelled`),
  `:agent_disabled`, `:agent_archived`, `:no_runtime`, `:runtime_disabled`,
  `:task_closed`, `:not_retryable` (a design run,
  `add-agent-conversation` decision 10, or a run-only autopilot run,
  `add-autopilots` decision 11), `{:already_retried, id}` (its retry is no longer queued;
  a queued one is returned) and `:rate_limited`.

  Lock order: actor, profile, task (`FOR UPDATE`), runtime, run.
  """
  @spec retry(Scope.t(), integer()) :: {:ok, Runs.summary()} | {:error, term()}
  def retry(%Scope{} = scope, run_id) when is_integer(run_id) do
    Workspaces.write_transaction(scope, :view_runs, nil, fn scope ->
      case Repo.one(
             from(r in Run, where: r.workspace_id == ^scope.workspace.id and r.id == ^run_id)
           ) do
        nil -> {:error, :not_found}
        snapshot -> retry_locked(scope, snapshot)
      end
    end)
  end

  defp retry_locked(scope, snapshot) do
    agent = Repo.one!(from(a in Actor, where: a.id == ^snapshot.agent_id, lock: "FOR SHARE"))

    profile =
      Repo.one(from(p in AgentProfile, where: p.actor_id == ^agent.id, lock: "FOR SHARE"))

    task =
      snapshot.task_id &&
        Repo.one!(from(t in Task, where: t.id == ^snapshot.task_id, lock: "FOR UPDATE"))

    runtime =
      profile && profile.runtime_id &&
        Repo.one(from(r in Runtime, where: r.id == ^profile.runtime_id, lock: "FOR SHARE"))

    run = lock_original(snapshot)

    with :ok <- Policy.authorize(scope, :retry_run, Stop.policy_resource(run)),
         :ok <- not_design(run),
         :ok <- ended(run),
         nil <- unavailable(agent, profile, runtime, run, task) do
      retry_once(run, retried?(run), scope, runtime)
    else
      reason when is_atom(reason) and reason != :ok -> {:error, reason}
      error -> error
    end
  end

  defp retry_once(_run, %Run{status: status} = queued, _scope, _runtime)
       when status in [:deferred, :queued],
       do: {:ok, Runs.summary(queued)}

  defp retry_once(_run, %Run{id: id}, _scope, _runtime), do: {:error, {:already_retried, id}}

  defp retry_once(run, nil, scope, runtime) do
    by = scope.actor && scope.actor.id

    with {:ok, queued} <- requeue(run, auto: false, by_actor_id: by, runtime_id: runtime.id),
         do: {:ok, Runs.summary(queued)}
  end

  # `add-agent-conversation` decision 10: the user sends the turn again.
  defp not_design(run),
    do:
      if(Runs.design_run?(run) or Runs.autopilot_run?(run),
        do: {:error, :not_retryable},
        else: :ok
      )

  defp ended(%Run{status: status}) when status in [:failed, :cancelled], do: :ok
  defp ended(_run), do: {:error, :not_ended}
end
