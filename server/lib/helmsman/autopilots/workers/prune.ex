defmodule Helmsman.Autopilots.Workers.Prune do
  @moduledoc """
  Daily (`add-autopilots` decision 15): deletes `skipped` records without
  a delivery ID older than 30 days. Records with a delivery ID (webhook
  deduplication is permanent) and every other status are kept.
  """

  use Oban.Worker, queue: :autopilots, max_attempts: 3

  import Ecto.Query

  alias Helmsman.Autopilots.{Clock, Record}
  alias Helmsman.Repo

  @keep_days 30

  @impl true
  def perform(%Oban.Job{}) do
    cutoff = DateTime.add(Clock.now(), -@keep_days * 86_400)

    Repo.delete_all(
      from(r in Record,
        where: r.status == :skipped and is_nil(r.delivery_id) and r.inserted_at < ^cutoff
      )
    )

    :ok
  end
end
