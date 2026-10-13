defmodule Helmsman.Dispatch.Workers.ReleaseDependents do
  @moduledoc """
  The re-check after a change that may satisfy the prerequisite
  `task_id` without the graph lock (`add-dependency-dispatch` decision 6):
  `Helmsman.Dispatch.Dependencies.recheck/1`. Inserted by
  `Helmsman.Dispatch.Dependencies.changed/1` in the transaction of the
  change; unique per task among jobs not yet executing, so a change while
  one executes gets the next one.
  """

  use Oban.Worker,
    queue: :default,
    unique: [keys: [:task_id], states: [:available, :scheduled, :retryable], period: :infinity]

  alias Helmsman.Dispatch.Dependencies

  @impl true
  def perform(%Oban.Job{args: %{"task_id" => task_id}}), do: Dependencies.recheck(task_id)
end
