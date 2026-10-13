defmodule Helmsman.AgentDesigns.SettleTurn do
  @moduledoc """
  Settles a design run's turn (`add-agent-conversation` decision 9),
  inserted in the transaction that ended the run
  (`Helmsman.Runs.after_ended/1`) and run in a new one after it
  (`Helmsman.AgentDesigns.settle/1`). Unique per run.
  """

  use Oban.Worker, queue: :runs, unique: [keys: [:run_id], period: :infinity]

  alias Helmsman.AgentDesigns

  @impl true
  def perform(%Oban.Job{args: %{"run_id" => run_id}}) do
    {:ok, _result} = AgentDesigns.settle(run_id)
    :ok
  end
end
