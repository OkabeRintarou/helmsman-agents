defmodule Helmsman.Filters do
  @moduledoc "Workspace saved queries, visibility, locking and commit notifications."
  import Ecto.Query
  alias Ecto.Changeset
  alias Helmsman.{BQL, Policy, Repo, Tx, Workspaces}
  alias Helmsman.Filters.SavedFilter
  alias Helmsman.Workspaces.Membership

  @spec list(Helmsman.Accounts.Scope.t()) :: {:ok, map()} | {:error, term()}
  def list(scope) do
    with :ok <- Policy.authorize(scope, :read_filters) do
      filters =
        scope |> visible() |> order_by([f], asc: f.name, asc: f.id) |> Repo.all() |> decorate()

      {mine, shared} =
        Enum.split_with(filters, &(scope.via != :run and &1.owner_id == scope.user.id))

      {:ok, %{mine: mine, shared: shared}}
    end
  end

  @spec get(Helmsman.Accounts.Scope.t(), term()) :: {:ok, SavedFilter.t()} | {:error, term()}
  def get(scope, id) do
    with :ok <- Policy.authorize(scope, :read_filters), {:ok, filter} <- fetch(scope, id) do
      {:ok, hd(decorate([filter]))}
    end
  end

  defp fetch(scope, id, lock? \\ false) do
    q = scope |> visible() |> where([f], f.id == ^id(id))
    q = if lock?, do: lock(q, "FOR UPDATE"), else: q

    case Repo.one(q) do
      nil -> {:error, :not_found}
      filter -> {:ok, filter}
    end
  end

  defp id(id) when is_integer(id) and id > 0 and id < 9_223_372_036_854_775_808, do: id

  defp id(id) when is_binary(id) do
    case Integer.parse(id) do
      {n, ""} when n > 0 and n < 9_223_372_036_854_775_808 -> n
      _ -> 0
    end
  end

  defp id(_), do: 0

  defp visible(scope) do
    ws = scope.workspace.id
    q = from(f in SavedFilter, where: f.workspace_id == ^ws)

    if scope.via == :run,
      do: where(q, [f], f.visibility == :workspace),
      else: where(q, [f], f.owner_id == ^scope.user.id or f.visibility == :workspace)
  end

  defp decorate([]), do: []

  defp decorate(filters) do
    filters = Repo.preload(filters, :owner)
    ws = hd(filters).workspace_id

    members =
      Repo.all(from(m in Membership, where: m.workspace_id == ^ws, select: m.user_id))
      |> MapSet.new()

    Enum.map(filters, fn f ->
      case BQL.parse(f.bql) do
        {:ok, _} ->
          %{f | valid_bql: true, owner_left: not MapSet.member?(members, f.owner_id)}

        {:error, {:invalid_bql, error}} ->
          %{
            f
            | valid_bql: false,
              bql_error: error,
              owner_left: not MapSet.member?(members, f.owner_id)
          }
      end
    end)
  end

  @spec create(Helmsman.Accounts.Scope.t(), map()) :: {:ok, SavedFilter.t()} | {:error, term()}
  def create(scope, attrs) do
    Workspaces.write_transaction(scope, :create_filter, fn scope ->
      # Serializes quota checks across sessions without upgrading a shared membership lock.
      Repo.one!(
        from(u in Helmsman.Accounts.User, where: u.id == ^scope.user.id, lock: "FOR UPDATE")
      )

      f = %SavedFilter{workspace_id: scope.workspace.id, owner_id: scope.user.id}
      changeset = SavedFilter.changeset(f, attrs)

      count =
        Repo.aggregate(
          from(f in SavedFilter,
            where: f.workspace_id == ^scope.workspace.id and f.owner_id == ^scope.user.id
          ),
          :count
        )

      changeset =
        if count >= 100,
          do: Changeset.add_error(changeset, :name, "at most 100 filters per workspace"),
          else: changeset

      with {:ok, f} <- Repo.insert(changeset) do
        notify(f)
        {:ok, hd(decorate([f]))}
      end
    end)
  end

  @spec update(Helmsman.Accounts.Scope.t(), term(), map()) ::
          {:ok, SavedFilter.t()} | {:error, term()}
  def update(scope, id, attrs) do
    Workspaces.write_transaction(scope, :read_filters, fn scope ->
      with {:ok, filter} <- fetch(scope, id, true),
           :ok <- Policy.authorize(scope, :update_filter, filter),
           :ok <- version(filter, attrs),
           changeset = SavedFilter.changeset(filter, attrs),
           :ok <- visibility(scope, filter, changeset),
           {:ok, updated} <- write(changeset) do
        notify_update(filter, updated)

        {:ok, hd(decorate([updated]))}
      end
    end)
  end

  defp notify_update(%{lock_version: version}, %{lock_version: version}), do: :ok

  defp notify_update(old, updated) do
    notify(old)
    if old.visibility != updated.visibility, do: notify(updated)
  end

  defp version(filter, attrs) do
    v = Map.get(attrs, :lock_version, Map.get(attrs, "lock_version"))
    if is_nil(v) or v == filter.lock_version, do: :ok, else: {:error, :stale}
  end

  defp visibility(scope, filter, changeset) do
    if Changeset.get_field(changeset, :visibility) != filter.visibility,
      do: Policy.authorize(scope, :change_filter_visibility, filter),
      else: :ok
  end

  defp write(%Changeset{valid?: false} = c), do: {:error, c}
  defp write(%Changeset{changes: changes} = c) when map_size(changes) == 0, do: {:ok, c.data}
  defp write(c), do: c |> Changeset.optimistic_lock(:lock_version) |> Repo.update()
  @spec delete(Helmsman.Accounts.Scope.t(), term()) :: {:ok, SavedFilter.t()} | {:error, term()}
  def delete(scope, id) do
    Workspaces.write_transaction(scope, :read_filters, fn scope ->
      with {:ok, f} <- fetch(scope, id, true),
           :ok <- Policy.authorize(scope, :delete_filter, f),
           {:ok, deleted} <- Repo.delete(f) do
        notify(f)
        {:ok, deleted}
      end
    end)
  end

  @doc false
  def cascade_removal(workspace_id, user_id) do
    Repo.delete_all(
      from(f in SavedFilter,
        where:
          f.workspace_id == ^workspace_id and f.owner_id == ^user_id and f.visibility == :private
      )
    )

    Tx.after_commit(fn ->
      Phoenix.PubSub.broadcast(
        Helmsman.PubSub,
        "workspace:#{workspace_id}:filters:#{user_id}",
        {:filters_changed, :private}
      )
    end)

    Tx.after_commit(fn ->
      Phoenix.PubSub.broadcast(
        Helmsman.PubSub,
        "workspace:#{workspace_id}:filters",
        {:filters_changed, :workspace}
      )
    end)

    :ok
  end

  defp notify(f) do
    {topic, visibility} =
      if f.visibility == :workspace,
        do: {"workspace:#{f.workspace_id}:filters", :workspace},
        else: {"workspace:#{f.workspace_id}:filters:#{f.owner_id}", :private}

    Tx.after_commit_once({:filter, topic}, fn ->
      Phoenix.PubSub.broadcast(Helmsman.PubSub, topic, {:filters_changed, visibility})
    end)
  end
end
