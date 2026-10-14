defmodule Helmsman.Runs.Workers.PruneTokens do
  @moduledoc """
  Every day (`add-release-distribution` decision 8): deletes the `hmr_`
  token rows that expired over 7 days ago or whose run ended over 7 days
  ago. Such a token no longer authenticates (it is valid for 24 hours and
  only while its run is active), so no valid token is deleted.

  Rows go in batches of 1000 by ID, each batch its own statement, at most
  50 batches per execution: the next day continues.
  """

  use Oban.Worker, queue: :default

  import Ecto.Query

  alias Helmsman.Repo
  alias Helmsman.Runs.{Run, RunToken}

  @batch 1_000
  @max_batches 50
  @days 7

  @impl true
  def perform(_job) do
    prune()
    :ok
  end

  @doc """
  Deletes the prunable rows and returns how many. Options: `:now`,
  `:batch` (default #{@batch}), `:max_batches` (default #{@max_batches}).
  """
  @spec prune(keyword()) :: non_neg_integer()
  def prune(opts \\ []) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
    cutoff = DateTime.add(now, -@days * 86_400, :second)
    batch = Keyword.get(opts, :batch, @batch)
    max_batches = Keyword.get(opts, :max_batches, @max_batches)

    delete_batches(cutoff, batch, max_batches, 0)
  end

  defp delete_batches(_cutoff, _batch, 0, deleted), do: deleted

  defp delete_batches(cutoff, batch, batches_left, deleted) do
    ids =
      Repo.all(
        from(t in RunToken,
          join: r in Run,
          on: r.id == t.run_id,
          where: t.expires_at < ^cutoff or r.finished_at < ^cutoff,
          order_by: t.id,
          limit: ^batch,
          select: t.id
        )
      )

    {count, _} = Repo.delete_all(from(t in RunToken, where: t.id in ^ids))

    if length(ids) == batch,
      do: delete_batches(cutoff, batch, batches_left - 1, deleted + count),
      else: deleted + count
  end
end
