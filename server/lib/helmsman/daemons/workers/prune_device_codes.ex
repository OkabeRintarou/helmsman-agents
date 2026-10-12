defmodule Helmsman.Daemons.Workers.PruneDeviceCodes do
  @moduledoc "Prunes expired device codes after one day."
  use Oban.Worker, queue: :daemons
  import Ecto.Query
  @impl true
  def perform(_job) do
    cutoff = DateTime.add(Helmsman.Daemons.now(), -86_400)
    Helmsman.Repo.delete_all(from c in Helmsman.Daemons.DeviceCode, where: c.expires_at < ^cutoff)
    :ok
  end
end
