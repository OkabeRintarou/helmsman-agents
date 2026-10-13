defmodule Helmsman.LocalRepositories.Workers.RecordBranch do
  @moduledoc """
  Records the task branch of a local-mode run that pushed to it
  (`add-local-repositories` decision 9): inserted in the transaction that
  recorded the push, run after it in the lock order of task writes
  (designs/13 §4.4). Unique per run; `Helmsman.LocalRepositories.record_branch/1`
  recomputes from every push record, so any order gives the same result.
  """

  use Oban.Worker, queue: :runs, unique: [keys: [:run_id], period: :infinity]

  alias Helmsman.LocalRepositories

  @impl true
  def perform(%Oban.Job{args: %{"run_id" => run_id}}) do
    {:ok, _result} = LocalRepositories.record_branch(run_id)
    :ok
  end
end
