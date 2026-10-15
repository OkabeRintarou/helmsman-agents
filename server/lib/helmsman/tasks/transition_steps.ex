defmodule Helmsman.Tasks.TransitionSteps do
  @moduledoc """
  The steps that run after a transition is written, in the same
  transaction (designs/05 §3, steps 7–8): Epic cascade, run dispatch, PR
  reconciliation. Each later change appends its step to `@steps`; a step
  returning `{:error, reason}` rolls the whole transition back.

  Steps, in order: the Epic cascade (`Helmsman.Tasks.Epics.after_transition/3`),
  then `Helmsman.Links.after_transition/3` (dependents' deferred runs
  released, their notifications), then
  `Helmsman.Dispatch.Dependencies.after_transition/3` (a cancelled or
  verified task's runs deferred by a dependency cancelled), then the pull
  request reconciliation, then `Helmsman.Autopilots.after_transition/3`
  (a task an autopilot started reached a final status: it is settled), then
  `Helmsman.Squads.EpicWatch.after_transition/3` (a stall check of the
  task's epic led by a squad, a job only).
  The triggers of `add-continuation-triggers` run right after the steps
  (`Helmsman.Tasks.transition/4`), not as a step: they are planned before
  the task row is locked.
  """

  alias Helmsman.Accounts.Scope
  alias Helmsman.Tasks.{Task, TaskEvent}

  @type step :: (Task.t(), TaskEvent.t(), Scope.t() -> :ok | {:error, term()})

  @steps [
    &Helmsman.Tasks.Epics.after_transition/3,
    &Helmsman.Links.after_transition/3,
    &Helmsman.Dispatch.Dependencies.after_transition/3,
    &Helmsman.GitHub.PullRequests.after_transition/3,
    &Helmsman.Autopilots.after_transition/3,
    &Helmsman.Squads.EpicWatch.after_transition/3
  ]

  @doc "Runs every step in order; stops at the first error."
  @spec run(Task.t(), TaskEvent.t(), Scope.t()) :: :ok | {:error, term()}
  def run(%Task{} = task, %TaskEvent{} = event, %Scope{} = scope),
    do: run(steps(), task, event, scope)

  @doc false
  @spec run([step()], Task.t(), TaskEvent.t(), Scope.t()) :: :ok | {:error, term()}
  def run(steps, task, event, scope) when is_list(steps) do
    Enum.reduce_while(steps, :ok, fn step, :ok ->
      case step.(task, event, scope) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  # Tests may append steps of their own for the calling process.
  if Mix.env() == :test do
    defp steps, do: @steps ++ Process.get(:helmsman_extra_transition_steps, [])
  else
    defp steps, do: @steps
  end
end
