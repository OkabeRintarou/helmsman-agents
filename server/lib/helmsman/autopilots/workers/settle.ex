defmodule Helmsman.Autopilots.Workers.Settle do
  @moduledoc """
  Settles an autopilot's started record (`add-autopilots` decision 8):
  `Helmsman.Autopilots.Settle.settle/1`. Unique while waiting to run.
  """

  use Oban.Worker,
    queue: :autopilots,
    max_attempts: 5,
    unique: [keys: [:autopilot_id], states: [:available, :scheduled]]

  alias Helmsman.Autopilots.Settle

  @impl true
  def perform(%Oban.Job{args: %{"autopilot_id" => id}}) do
    {:ok, _result} = Settle.settle(id)
    :ok
  end
end
