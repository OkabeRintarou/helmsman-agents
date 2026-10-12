defmodule Helmsman.Runs.Workers.Retry do
  @moduledoc """
  The automatic retry of a failed run (`add-run-lifecycle` decision 25),
  inserted in the transaction that ended it: `Helmsman.Runs.Retry.perform/1`.
  Unique per run; running it again does nothing.
  """

  use Oban.Worker, queue: :runs, unique: [keys: [:run_id], period: :infinity]

  alias Helmsman.Runs.Retry, as: Requeue

  @impl true
  def perform(%Oban.Job{args: %{"run_id" => run_id}}) do
    {:ok, _result} = Requeue.perform(run_id)
    :ok
  end
end
