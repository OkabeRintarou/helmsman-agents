defmodule Helmsman.Accounts.Workers.PruneUserTokens do
  @moduledoc """
  Every day (`add-release-distribution` decision 8): deletes the expired
  rows of `users_tokens`: sessions, magic links (`login`) and email
  changes (`change:…`) older than their validity in
  `Helmsman.Accounts.UserToken.validity_seconds/0`. Rows of other contexts
  are kept.

  Rows go in batches of 1000 by ID, each batch its own statement, at most
  50 batches per execution: the next day continues.
  """

  use Oban.Worker, queue: :default

  import Ecto.Query

  alias Helmsman.Accounts.UserToken
  alias Helmsman.Repo

  @batch 1_000
  @max_batches 50

  @impl true
  def perform(_job) do
    prune()
    :ok
  end

  @doc """
  Deletes the expired rows and returns how many. Options: `:now`,
  `:batch` (default #{@batch}), `:max_batches` (default #{@max_batches}).
  """
  @spec prune(keyword()) :: non_neg_integer()
  def prune(opts \\ []) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
    batch = Keyword.get(opts, :batch, @batch)
    max_batches = Keyword.get(opts, :max_batches, @max_batches)

    delete_batches(expired(now), batch, max_batches, 0)
  end

  defp expired(now) do
    %{session: session, login: login, change: change} = UserToken.validity_seconds()

    before = fn seconds ->
      now |> DateTime.add(-seconds, :second) |> DateTime.truncate(:second)
    end

    from(t in UserToken,
      where:
        (t.context == "session" and t.inserted_at < ^before.(session)) or
          (t.context == "login" and t.inserted_at < ^before.(login)) or
          (like(t.context, "change:%") and t.inserted_at < ^before.(change))
    )
  end

  defp delete_batches(_query, _batch, 0, deleted), do: deleted

  defp delete_batches(query, batch, batches_left, deleted) do
    ids = Repo.all(from(t in query, order_by: t.id, limit: ^batch, select: t.id))
    {count, _} = Repo.delete_all(from(t in UserToken, where: t.id in ^ids))

    if length(ids) == batch,
      do: delete_batches(query, batch, batches_left - 1, deleted + count),
      else: deleted + count
  end
end
