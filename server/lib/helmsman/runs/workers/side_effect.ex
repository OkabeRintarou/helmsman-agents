defmodule Helmsman.Runs.Workers.SideEffect do
  @moduledoc """
  An effect of a run on its task (designs/13 §4.4, `add-run-lifecycle`
  decision 12), inserted in the transaction that changed the run and run
  in a new one after it: `auto_claim` when it started, `fallback` when it
  succeeded, `steer_settle` when it succeeded with an acknowledged
  steering push (`add-run-steering` decision 7), `delegate_done` when a
  delegated run ended and wakes its leader (`add-squads` decision 9),
  `spec_settle` when a run with review requests ended for good
  (`add-spec-workflow` decision 10). Unique per run and kind;
  each effect is idempotent.
  """

  use Oban.Worker, queue: :runs, unique: [keys: [:run_id, :kind], period: :infinity]

  alias Helmsman.Runs.{SideEffects, Steering}

  @impl true
  def perform(%Oban.Job{args: %{"run_id" => run_id, "kind" => "auto_claim"}}) do
    {:ok, _result} = SideEffects.auto_claim(run_id)
    :ok
  end

  def perform(%Oban.Job{args: %{"run_id" => run_id, "kind" => "fallback"}}) do
    {:ok, _result} = SideEffects.fallback(run_id)
    :ok
  end

  def perform(%Oban.Job{args: %{"run_id" => run_id, "kind" => "steer_settle"}}) do
    {:ok, _count} = Steering.settle(run_id)
    :ok
  end

  def perform(%Oban.Job{args: %{"run_id" => run_id, "kind" => "delegate_done"}}) do
    :ok = SideEffects.delegate_done(run_id)
  end

  def perform(%Oban.Job{args: %{"run_id" => run_id, "kind" => "spec_settle"}}) do
    :ok = Helmsman.TaskSpecs.settle_run(run_id)
  end
end
