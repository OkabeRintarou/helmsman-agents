defmodule Helmsman.Runs.Workers.PruneEvents do
  @moduledoc """
  Every day (decision 17): deletes the execution events of runs that
  ended over 30 days ago, 100 runs per batch until none is left, and marks
  them `events_pruned_at`. Runs themselves are kept.
  """

  use Oban.Worker, queue: :runs

  import Ecto.Query

  alias Helmsman.Repo
  alias Helmsman.Runs.{Run, RunEvent}
  alias Helmsman.Tx

  @batch 100
  @days 30

  @impl true
  def perform(_job) do
    cutoff = DateTime.add(DateTime.utc_now(), -@days * 86_400, :second)
    prune(cutoff)
  end

  defp prune(cutoff) do
    {:ok, count} =
      Tx.run(fn ->
        ids =
          Repo.all(
            from(r in Run,
              where: r.finished_at < ^cutoff and is_nil(r.events_pruned_at),
              order_by: r.id,
              limit: @batch,
              lock: "FOR UPDATE SKIP LOCKED",
              select: r.id
            )
          )

        Repo.delete_all(from(e in RunEvent, where: e.run_id in ^ids))

        Repo.update_all(from(r in Run, where: r.id in ^ids),
          set: [events_pruned_at: DateTime.utc_now()]
        )

        {:ok, length(ids)}
      end)

    if count == @batch, do: prune(cutoff), else: :ok
  end
end
