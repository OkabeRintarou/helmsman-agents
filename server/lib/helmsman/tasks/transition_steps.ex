defmodule Helmsman.Tasks.TransitionSteps do
  @moduledoc """
  The steps that run after a transition is written, in the same
  transaction (designs/05 §3, steps 7–8): Epic cascade, run dispatch, PR
  reconciliation. Each later change appends its step to `@steps`; a step
  returning `{:error, reason}` rolls the whole transition back.

  This change has no steps yet.
  """

  alias Helmsman.Accounts.Scope
  alias Helmsman.Tasks.{Task, TaskEvent}

  @type step :: (Task.t(), TaskEvent.t(), Scope.t() -> :ok | {:error, term()})

  @steps []

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

  defp steps, do: @steps
end
