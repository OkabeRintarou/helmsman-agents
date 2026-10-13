defmodule Helmsman.Autopilots.Workers.StartPending do
  @moduledoc """
  Starts a queued autopilot request once nothing is started
  (`add-autopilots` decision 6): `Helmsman.Autopilots.Fire.start_pending/1`.
  Running it again, or for a request that is no longer pending, does
  nothing.
  """

  use Oban.Worker,
    queue: :autopilots,
    max_attempts: 5,
    unique: [keys: [:autopilot_run_id], states: [:available, :scheduled, :retryable]]

  alias Helmsman.Autopilots.Fire

  @impl true
  def perform(%Oban.Job{args: %{"autopilot_run_id" => id}}) do
    case Fire.start_pending(id) do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
