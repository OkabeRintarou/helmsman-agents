defmodule Helmsman.GitHub.Workers.PruneDeliveries do
  @moduledoc "Daily: deletes webhook delivery records older than 7 days."

  use Oban.Worker, queue: :default, max_attempts: 3

  import Ecto.Query, warn: false

  alias Helmsman.GitHub.Delivery
  alias Helmsman.Repo

  @max_age_days 7

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    cutoff = DateTime.add(DateTime.utc_now(:second), -@max_age_days, :day)
    Repo.delete_all(from(d in Delivery, where: d.received_at < ^cutoff))
    :ok
  end
end
