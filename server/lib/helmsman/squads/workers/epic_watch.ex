defmodule Helmsman.Squads.Workers.EpicWatch do
  @moduledoc """
  A stall check of one epic (`Helmsman.Squads.EpicWatch.check/1`,
  `improve-squad-leader-orchestration` decision 11). At most one waits per
  epic: inserting another moves the waiting one to the new time.
  """

  use Oban.Worker,
    queue: :default,
    unique: [keys: [:epic_id], states: [:available, :scheduled], period: :infinity],
    replace: [scheduled: [:scheduled_at], available: [:scheduled_at]]

  alias Helmsman.Squads.EpicWatch

  @impl true
  def perform(%Oban.Job{args: %{"epic_id" => epic_id}}) do
    _result = EpicWatch.check(epic_id)
    :ok
  end
end
