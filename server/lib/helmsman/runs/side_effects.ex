defmodule Helmsman.Runs.SideEffects do
  @moduledoc """
  The effects of a run on its task (designs/13 §4.4, §7,
  `add-run-lifecycle` decision 12), each in its own transaction after the
  run's change committed (`Helmsman.Runs.Workers.SideEffect`), in the lock
  order of task writes, at most once per run (unique indexes). Neither
  needs the agent to be usable still: the run has happened.
  """

  import Ecto.Query, warn: false

  alias Helmsman.Accounts.Scope
  alias Helmsman.Actors.Actor
  alias Helmsman.Feedback
  alias Helmsman.Feedback.Entry
  alias Helmsman.Locks
  alias Helmsman.Repo
  alias Helmsman.Runs.Run
  alias Helmsman.Tasks
  alias Helmsman.Tasks.Task
  alias Helmsman.Tx

  @doc """
  The run `run_id` started: its task goes to `in_progress` if it is still
  `new` and assigned to the agent (`Helmsman.Tasks.auto_claim_for_run/1`).
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
