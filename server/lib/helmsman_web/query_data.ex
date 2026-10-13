defmodule HelmsmanWeb.QueryData do
  @moduledoc """
  The BQL page's and the sidebar's access to BQL, task queries and saved filters
  (add-search-query-ui D10), plus the UI-side permission helpers (the domain checks
  again).

  The editor and saves always keep the user's own text: `Helmsman.BQL.to_string/1` is
  display-only and never replaces the query.
  """

  alias Helmsman.{BQL, Filters, Tasks}
  alias Helmsman.Filters.SavedFilter

  @type filter :: SavedFilter.t()

  @doc "`BQL.parse/1`: `:ok` or `{:error, %{message, position}}`."
  @spec parse(String.t()) :: :ok | {:error, %{message: String.t(), position: pos_integer()}}
  def parse(bql) when is_binary(bql) do
    case BQL.parse(bql) do
      {:ok, _ast} -> :ok
      {:error, {:invalid_bql, %{} = error}} -> {:error, error}
    end
  end

  @doc "`BQL.fields/0`."
  @spec fields() :: [map()]
  def fields, do: BQL.fields()

  @doc "`Tasks.query/3` with a BQL string."
  @spec query(map(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def query(scope, bql, opts), do: Tasks.query(scope, bql, opts)

  @doc "`Filters.list/1`: `{:ok, %{mine: [filter], shared: [filter]}}`."
  @spec list_filters(map()) :: {:ok, map()} | {:error, term()}
  def list_filters(scope), do: Filters.list(scope)

  @doc "`Filters.get/2`."
  @spec get_filter(map(), term()) :: {:ok, filter} | {:error, term()}
  def get_filter(scope, id), do: Filters.get(scope, id)

  @doc "`Filters.create/2` (`name`, `bql`, `visibility`)."
  @spec create_filter(map(), map()) :: {:ok, filter} | {:error, term()}
  def create_filter(scope, attrs), do: Filters.create(scope, attrs)

  @doc "`Filters.update/3` (`name`, `bql`, `visibility`, `lock_version`)."
  @spec update_filter(map(), term(), map()) :: {:ok, filter} | {:error, term()}
  def update_filter(scope, id, attrs), do: Filters.update(scope, id, attrs)

  @doc "`Filters.delete/2`."
  @spec delete_filter(map(), term()) :: {:ok, filter} | {:error, term()}
  def delete_filter(scope, id), do: Filters.delete(scope, id)

  # `Helmsman.Filters` broadcasts on these topics but does not export them.
  @doc "Topic of the workspace's shared filters (`{:filters_changed, :workspace}`)."
  @spec topic(integer()) :: String.t()
  def topic(workspace_id), do: "workspace:#{workspace_id}:filters"

  @doc "Topic of a user's private filters (`{:filters_changed, :private}`)."
  @spec topic(integer(), integer()) :: String.t()
  def topic(workspace_id, user_id), do: "workspace:#{workspace_id}:filters:#{user_id}"

  @doc """
  Whether the user of `scope` may rename, re-query or delete `filter`: its owner, or an
  admin or owner of the workspace when it is shared (the domain checks again).
  """
  @spec can_edit?(map(), filter) :: boolean()
  def can_edit?(%{user: %{id: user_id}, role: role}, filter) do
    role in [:owner, :admin, :member] and
      (filter.owner_id == user_id or
         (role in [:owner, :admin] and filter.visibility == :workspace))
  end

  def can_edit?(_scope, _filter), do: false

  @doc "Only the owner changes a filter's visibility."
  @spec can_change_visibility?(map(), filter) :: boolean()
  def can_change_visibility?(%{user: %{id: user_id}, role: role}, filter),
    do: role in [:owner, :admin, :member] and filter.owner_id == user_id

  def can_change_visibility?(_scope, _filter), do: false

  @doc "Members and above save filters; viewers only read."
  @spec can_save?(map()) :: boolean()
  def can_save?(%{role: role}), do: role in [:owner, :admin, :member]
  def can_save?(_scope), do: false

  @doc "Whether the filter's owner has left the workspace."
  @spec owner_left?(filter) :: boolean()
  def owner_left?(filter), do: filter.owner_left == true or filter.owner == nil

  @doc "The display name of the filter's owner (nil when they left)."
  @spec owner_name(filter) :: String.t() | nil
  def owner_name(filter) do
    if owner_left?(filter), do: nil, else: filter.owner.display_name
  end
end
