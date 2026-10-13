defmodule Helmsman.Runs.SideEffects do
  @moduledoc """
  The effects of a run on its task (designs/13 §4.4, §7,
  `add-run-lifecycle` decision 12), each in its own transaction after the
  run's change committed (`Helmsman.Runs.Workers.SideEffect`), in the lock
  order of task writes, at most once per run (unique indexes). Neither
  needs the agent to be usable still: the run has happened.
  """

  import Ecto.Query, warn: false

  require Logger

  alias Helmsman.Accounts.Scope
  alias Helmsman.Actors.Actor
  alias Helmsman.Feedback
  alias Helmsman.Feedback.Entry
  alias Helmsman.Locks
  alias Helmsman.Repo
  alias Helmsman.Runs.{Origin, Run}
  alias Helmsman.Squads.Dispatch, as: SquadDispatch
  alias Helmsman.Squads.Squad
  alias Helmsman.Tasks
  alias Helmsman.Tasks.Task
  alias Helmsman.Tx

  @doc """
  The run `run_id` started: its task goes to `in_progress` if it is still
  `new` and assigned to the agent, or to the squad the run is a leader of
  (`Helmsman.Tasks.auto_claim_for_run/1`).
  """
  @spec auto_claim(pos_integer()) :: {:ok, :claimed | :skipped}
  def auto_claim(run_id) do
    case Repo.get(Run, run_id) do
      nil -> {:ok, :skipped}
      run -> Tasks.auto_claim_for_run(run)
    end
  end

  @doc """
  The run `run_id` succeeded: when nothing was written in it as feedback
  and its last output is not blank, the agent comments it on the task,
  marked as a fallback (maintenance lock, task row `FOR UPDATE`).
  """
  @spec fallback(pos_integer()) :: {:ok, :commented | :skipped}
  def fallback(run_id) do
    Tx.run(fn ->
      with %Run{status: :succeeded, task_id: task_id} = run when not is_nil(task_id) <-
             Repo.get(Run, run_id),
           false <- blank?(run.summary) do
        fallback_locked(run, task_id)
      else
        _skip -> {:ok, :skipped}
      end
    end)
  end

  defp fallback_locked(run, task_id) do
    Locks.maint_shared!(run.workspace_id)
    task = Repo.one!(from(t in Task, where: t.id == ^task_id, lock: "FOR UPDATE"))

    if Repo.exists?(from(f in Entry, where: f.source_run_id == ^run.id)),
      do: {:ok, :skipped},
      else: comment(task, run)
  end

  @doc """
  The delegated run `run_id` ended (`add-squads` decision 9): for each
  `(squad, leader run)` of its `delegated` triggers, the squad's current
  leader gets a `delegate_done` trigger as the squad, authorized and
  chained like the leader's run that delegated (by the member); several
  sources merge into one queued run, each trigger with its own source.
  Skipped quietly when the task is no longer `new` or `in_progress`, no
  longer assigned to the squad, the squad is disabled, or a run already
  carries the wake-up of this source.
  Each in its own transaction, in the order of task writes (maintenance
  lock, the squad's rows, the task row). A trigger that is not dispatched
  is only logged.
  """
  @spec delegate_done(pos_integer()) :: :ok
  def delegate_done(run_id) do
    case Repo.get(Run, run_id) do
      nil ->
        :ok

      run ->
        run.triggers
        |> Enum.filter(&(&1["kind"] == "delegated"))
        |> Enum.map(&{&1["squad_id"], &1["leader_run_id"]})
        |> Enum.uniq()
        |> Enum.each(fn {squad_id, leader_run_id} -> wake(run, squad_id, leader_run_id) end)

        :ok
    end
  end

  defp wake(run, squad_id, leader_run_id) do
    {:ok, _result} =
      Tx.run(fn ->
        Locks.maint_shared!(run.workspace_id)

        with %Squad{actor_id: actor_id} <- squad_id && Repo.get(Squad, squad_id),
             {:ok, loaded} <- SquadDispatch.lock_rows(actor_id),
             task = Repo.one!(from(t in Task, where: t.id == ^run.task_id, lock: "FOR UPDATE")),
             true <- wakes?(task, loaded, run, leader_run_id) do
          {:ok, wake_locked(run, loaded, task, leader_run_id)}
        else
          _skip -> {:ok, :skipped}
        end
      end)

    :ok
  end

  defp wakes?(task, loaded, run, leader_run_id) do
    task.status in [:new, :in_progress] and task.assignee_id == loaded.actor.id and
      is_nil(loaded.actor.disabled_at) and not woken?(task, run, loaded.squad.id, leader_run_id)
  end

  # Running the effect again finds the trigger it wrote for this source:
  # one wake-up per `(member run, squad, leader run)`, so the other sources
  # of a merged member run keep their own authorization and chain.
  defp woken?(task, run, squad_id, leader_run_id) do
    marker = [
      %{
        "kind" => "delegate_done",
        "delegated_run_id" => run.id,
        "squad_id" => squad_id,
        "leader_run_id" => leader_run_id
      }
    ]

    Repo.exists?(
      from(r in Run, where: r.task_id == ^task.id and fragment("? @> ?", r.triggers, ^marker))
    )
  end

  defp wake_locked(run, loaded, task, leader_run_id) do
    source = (leader_run_id && Repo.get(Run, leader_run_id)) || run
    member = Repo.get!(Actor, run.agent_id)

    origin = %Origin{
      by_actor_id: member.id,
      initiator_user_id: source.root_initiator_user_id,
      chain: Enum.reject(source.causal_agent_ids, &(&1 == loaded.leader.id))
    }

    trigger = %{
      kind: :delegate_done,
      instructions: nil,
      extra: %{
        "delegated_run_id" => run.id,
        "leader_run_id" => leader_run_id,
        "member" => member.name,
        "status" => Atom.to_string(run.status),
        "failure_reason" => run.failure_reason && Atom.to_string(run.failure_reason)
      }
    }

    target = %{agent: loaded.leader, profile: loaded.leader_profile, task: task, lane: :work}
    outcome = SquadDispatch.enqueue_as(origin, target, loaded.squad.id, trigger)

    if outcome.result == :skipped,
      do: Logger.info("delegate_done of run #{run.id} not dispatched: #{outcome.reason}")

    outcome
  end

  defp blank?(nil), do: true
  defp blank?(text), do: String.trim(text) == ""

  defp comment(task, run) do
    agent = Repo.get!(Actor, run.agent_id)

    {:ok, {_entry, task}} =
      Feedback.insert_locked(
        task,
        %Scope{actor: agent},
        %{kind: :comment, content: run.summary},
        fallback: true,
        source_run_id: run.id
      )

    Tasks.notify_summary(task)
    {:ok, :commented}
  end
end
