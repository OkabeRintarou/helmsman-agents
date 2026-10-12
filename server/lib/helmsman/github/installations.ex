defmodule Helmsman.GitHub.Installations do
  @moduledoc """
  Linking installations to workspaces, and every write to installations
  and repositories (designs/15 §1, add-github-app design decisions 6–8,
  16 and 17).

  Lock order, never skipped nor reversed: workspace maintenance lock
  (shared) → membership row (user writes only) → project row → installation
  row → repository rows. User writes go through
  `Helmsman.Workspaces.write_transaction/4`, background writes through
  `system_write/2`. Disconnecting, syncing and refreshing all lock the
  installation row `FOR UPDATE`, so they are serialized per installation.

  GitHub requests always run outside the transaction; their results carry
  the time they were fetched and are only applied when newer than the
  result already applied (`apply_details/3`, `apply_repositories/3`).
  Every commit that changes something broadcasts exactly one
  `{:github_changed}` on the workspace topic.
  """

  import Ecto.Query, warn: false

  alias Helmsman.Accounts.Scope
  alias Helmsman.Events
  alias Helmsman.GitHub.AppConfig
  alias Helmsman.GitHub.Client
  alias Helmsman.GitHub.Installation
  alias Helmsman.GitHub.OAuth
  alias Helmsman.GitHub.Repository
  alias Helmsman.GitHub.Tokens
  alias Helmsman.GitHub.Workers.SyncRepositories
  alias Helmsman.Locks
  alias Helmsman.Policy
  alias Helmsman.Repo
  alias Helmsman.Tx
  alias Helmsman.Workspaces
  alias Helmsman.Workspaces.Workspace

  @type details :: %{
          account_login: String.t(),
          account_type: String.t(),
          suspended_at: DateTime.t() | nil
        }

  @type connect_error ::
          :forbidden
          | :not_found
          | :oauth_required
          | :oauth_failed
          | :installation_not_accessible
          | :installation_taken
          | :already_connected
          | :stale
          | Client.error()

  ## Reading

  @doc "Returns the installation with GitHub ID `installation_id`, or nil."
  @spec get_by_github_id(integer()) :: Installation.t() | nil
  def get_by_github_id(installation_id) when is_integer(installation_id),
    do: Repo.get_by(Installation, installation_id: installation_id)

  @doc """
  Returns the workspace's connected installation or, when none, the one
  disconnected last; nil when it never had one.
  """
  @spec for_workspace(pos_integer()) :: Installation.t() | nil
  def for_workspace(workspace_id) do
    Repo.one(
      from(i in Installation,
        where: i.workspace_id == ^workspace_id,
        order_by: [
          desc: is_nil(i.disconnected_at),
          desc_nulls_first: i.disconnected_at,
          desc: i.id
        ],
        limit: 1
      )
    )
  end

  @doc "Lists the installations that are not disconnected."
  @spec list_connected() :: [Installation.t()]
  def list_connected,
    do: Repo.all(from(i in Installation, where: is_nil(i.disconnected_at), order_by: i.id))

  ## Fetching from GitHub

  @doc """
  Fetches the installation's details with the App JWT: `{:ok, details}`, or
  `:gone` when GitHub answers 404.
  """
  @spec fetch_details(integer()) :: {:ok, details()} | :gone | {:error, Client.error()}
  def fetch_details(installation_id) do
    case Client.request(:get, "/app/installations/#{installation_id}", auth: :app) do
      {:ok, %{"account" => %{"login" => login, "type" => type}} = body} ->
        {:ok,
         %{
           account_login: login,
           account_type: type,
           suspended_at: parse_time(body["suspended_at"])
         }}

      {:ok, _body} ->
        {:error, {:github_unavailable, :unexpected_response}}

      {:error, :not_found} ->
        :gone

      {:error, _reason} = error ->
        error
    end
  end

  defp parse_time(nil), do: nil

  defp parse_time(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, at, _offset} -> DateTime.truncate(at, :second)
      _ -> nil
    end
  end

  ## Connecting

  @doc """
  Links GitHub installation `installation_id` to the scope's workspace
  (`:manage_github`) after proving with the OAuth `code` that the GitHub
  user can access it (design decision 6).

  Errors: `:oauth_required` (no code: the App does not request user
  authorization on install), `:installation_not_accessible` (not in the
  user's installations), `:installation_taken` (linked to another
  workspace), `:already_connected` (the workspace has another connected
  installation), `:stale` (a newer read of the installation was applied
  meanwhile; connect again).
  """
  @spec connect(Scope.t(), integer(), String.t() | nil) ::
          {:ok, Installation.t()} | {:error, connect_error()}
  def connect(%Scope{workspace: %Workspace{}} = scope, installation_id, code)
      when is_integer(installation_id) do
    with :ok <- Policy.authorize(scope, :manage_github),
         {:ok, code} <- require_code(code),
         {:ok, config} <- AppConfig.current(),
         {:ok, ids} <- OAuth.user_installation_ids(config, code),
         :ok <- accessible(installation_id, ids),
         fetched_at = DateTime.utc_now(),
         {:ok, details} <- fetch_accessible_details(installation_id) do
      Workspaces.write_transaction(scope, :manage_github, fn scope ->
        link(scope.workspace.id, installation_id, details, fetched_at, 1)
      end)
    end
  end

  defp require_code(code) when is_binary(code) and code != "", do: {:ok, code}
  defp require_code(_code), do: {:error, :oauth_required}

  defp accessible(installation_id, ids) do
    if installation_id in ids, do: :ok, else: {:error, :installation_not_accessible}
  end

  defp fetch_accessible_details(installation_id) do
    case fetch_details(installation_id) do
      :gone -> {:error, :installation_not_accessible}
      other -> other
    end
  end

  defp link(workspace_id, installation_id, details, fetched_at, attempts_left) do
    case lock_by_github_id(installation_id) do
      nil ->
        insert(workspace_id, installation_id, details, fetched_at, attempts_left)

      %Installation{workspace_id: ^workspace_id} = row ->
        reconnect(row, details, fetched_at)

      %Installation{} ->
        {:error, :installation_taken}
    end
  end

  defp insert(workspace_id, installation_id, details, fetched_at, attempts_left) do
    changeset =
      %Installation{workspace_id: workspace_id, installation_id: installation_id}
      |> Ecto.Changeset.change(Map.put(details, :fetched_at, fetched_at))
      |> one_connected_constraint()

    case Repo.insert(changeset, on_conflict: :nothing, conflict_target: :installation_id) do
      # A concurrent connection inserted the row first: decide again on it.
      {:ok, %Installation{id: nil}} when attempts_left > 0 ->
        link(workspace_id, installation_id, details, fetched_at, attempts_left - 1)

      {:ok, %Installation{id: nil}} ->
        {:error, :stale}

      {:ok, row} ->
        connected(row)

      {:error, _changeset} ->
        {:error, :already_connected}
    end
  end

  defp reconnect(row, details, fetched_at) do
    with {:ok, row} <- apply_or_stale(row, details, fetched_at),
         {:ok, row} <-
           row
           |> Ecto.Changeset.change(disconnected_at: nil)
           |> one_connected_constraint()
           |> Repo.update()
           |> already_connected() do
      connected(row)
    end
  end

  defp apply_or_stale(row, details, fetched_at) do
    case apply_details(row, {:ok, details}, fetched_at) do
      :stale -> {:error, :stale}
      {:ok, row} -> {:ok, row}
    end
  end

  defp one_connected_constraint(changeset) do
    Ecto.Changeset.unique_constraint(changeset, :workspace_id,
      name: :github_installations_one_connected_index
    )
  end

  defp already_connected({:error, %Ecto.Changeset{}}), do: {:error, :already_connected}
  defp already_connected(result), do: result

  defp connected(row) do
    {:ok, _job} = Oban.insert(SyncRepositories.new(%{installation_id: row.installation_id}))
    notify(row.workspace_id)
    {:ok, row}
  end

  ## Disconnecting

  @doc """
  Disconnects the workspace's installation (`:manage_github`): only the
  local link is removed and every repository of the installation becomes
  unavailable; project bindings are kept. Connecting the same installation
  again restores it. `{:error, :not_found}` when nothing is connected.
  """
  @spec disconnect(Scope.t()) :: {:ok, Installation.t()} | {:error, :forbidden | :not_found}
  def disconnect(%Scope{workspace: %Workspace{}} = scope) do
    Workspaces.write_transaction(scope, :manage_github, fn scope ->
      query =
        from(i in Installation,
          where: i.workspace_id == ^scope.workspace.id and is_nil(i.disconnected_at),
          lock: "FOR UPDATE"
        )

      case Repo.one(query) do
        nil ->
          {:error, :not_found}

        row ->
          row = disconnect_row(row)
          notify(row.workspace_id)
          {:ok, row}
      end
    end)
  end

  # Local intent: only `disconnected_at` and the repositories' `removed_at`
  # change, never the remote fields nor `fetched_at`. Must run with the
  # installation row locked.
  defp disconnect_row(%Installation{} = row) do
    now = DateTime.utc_now(:second)

    from(r in Repository, where: r.installation_id == ^row.id and is_nil(r.removed_at))
    |> Repo.update_all(set: [removed_at: now, updated_at: now])

    row =
      if row.disconnected_at,
        do: row,
        else: row |> Ecto.Changeset.change(disconnected_at: now) |> Repo.update!()

    installation_id = row.installation_id
    Tx.after_commit(fn -> Tokens.purge(installation_id) end)
    row
  end

  ## Background writes

  @doc """
  Runs a background write on the installation with GitHub ID
  `installation_id` (design decision 16): in `Helmsman.Tx.run/2` with one
  retry, takes the workspace maintenance lock (shared; waits for an
  import), re-reads the installation row `FOR UPDATE` and calls `fun` with
  it. No role is checked. `{:error, :not_found}` for unknown installations.
  """
  @spec system_write(integer(), (Installation.t() -> Tx.result())) :: Tx.result()
  def system_write(installation_id, fun)
      when is_integer(installation_id) and is_function(fun, 1) do
    Tx.run(
      fn ->
        workspace_query =
          from(i in Installation,
            where: i.installation_id == ^installation_id,
            select: i.workspace_id
          )

        case Repo.one(workspace_query) do
          nil ->
            {:error, :not_found}

          workspace_id ->
            Locks.maint_shared!(workspace_id)
            fun.(lock_by_github_id(installation_id))
        end
      end,
      retry: 1
    )
  end

  defp lock_by_github_id(installation_id) do
    Repo.one(
      from(i in Installation, where: i.installation_id == ^installation_id, lock: "FOR UPDATE")
    )
  end

  @doc """
  The only function that writes an installation's remote fields (design
  decision 17). Must be called with `row` locked `FOR UPDATE`.

  A result fetched no later than `row.fetched_at` is stale: nothing is
  written and `:stale` is returned. Otherwise `{:ok, details}` writes the
  account, type, suspension and `fetched_at`; `:gone` disconnects the
  installation and writes `fetched_at`.
  """
  @spec apply_details(Installation.t(), {:ok, details()} | :gone, DateTime.t()) ::
          {:ok, Installation.t()} | :stale
  def apply_details(%Installation{} = row, result, %DateTime{} = fetched_at) do
    if newer?(fetched_at, row.fetched_at) do
      {:ok, write_details(row, result, fetched_at)}
    else
      :stale
    end
  end

  defp write_details(row, {:ok, details}, fetched_at) do
    row
    |> Ecto.Changeset.change(
      account_login: details.account_login,
      account_type: details.account_type,
      suspended_at: details.suspended_at,
      fetched_at: fetched_at
    )
    |> Repo.update!()
  end

  defp write_details(row, :gone, fetched_at) do
    row
    |> Ecto.Changeset.change(fetched_at: fetched_at)
    |> Repo.update!()
    |> disconnect_row()
  end

  defp newer?(_fetched_at, nil), do: true
  defp newer?(fetched_at, applied_at), do: DateTime.compare(fetched_at, applied_at) == :gt

  @doc """
  Applies a refresh of the installation's details fetched at `fetched_at`
  (`{:ok, details}` or `:gone`). Disconnected installations and stale
  results are dropped (`{:ok, :discarded}` / `{:ok, :stale}`).
  """
  @spec apply_refresh(integer(), {:ok, details()} | :gone, DateTime.t()) ::
          {:ok, :applied | :discarded | :stale} | {:error, :not_found}
  def apply_refresh(installation_id, result, fetched_at) do
    system_write(installation_id, fn
      %Installation{disconnected_at: %DateTime{}} ->
        {:ok, :discarded}

      row ->
        case apply_details(row, result, fetched_at) do
          :stale ->
            {:ok, :stale}

          {:ok, row} ->
            notify(row.workspace_id)
            {:ok, :applied}
        end
    end)
  end

  @doc """
  Applies the installation's repository list fetched at `fetched_at` (raw
  GitHub repository objects): upserts them by GitHub ID, restores the ones
  that reappeared and marks the missing ones removed. Dropped when the
  installation is disconnected (`{:ok, :discarded}`) or a list fetched
  later was already applied (`{:ok, :stale}`).
  """
  @spec apply_repositories(integer(), [map()], DateTime.t()) ::
          {:ok, :applied | :discarded | :stale} | {:error, :not_found}
  def apply_repositories(installation_id, repositories, %DateTime{} = fetched_at) do
    system_write(installation_id, fn
      %Installation{disconnected_at: %DateTime{}} ->
        {:ok, :discarded}

      row ->
        if newer?(fetched_at, row.repos_fetched_at) do
          write_repositories(row, repositories, fetched_at)
          notify(row.workspace_id)
          {:ok, :applied}
        else
          {:ok, :stale}
        end
    end)
  end

  defp write_repositories(row, repositories, fetched_at) do
    now = DateTime.utc_now(:second)

    entries =
      repositories
      |> Enum.map(&repository_entry(&1, row, now))
      |> Enum.uniq_by(& &1.github_id)

    entries
    |> Enum.chunk_every(500)
    |> Enum.each(fn chunk ->
      Repo.insert_all(Repository, chunk,
        on_conflict:
          {:replace,
           [
             :installation_id,
             :owner,
             :name,
             :default_branch,
             :archived,
             :private,
             :removed_at,
             :updated_at
           ]},
        conflict_target: [:workspace_id, :github_id]
      )
    end)

    github_ids = Enum.map(entries, & &1.github_id)

    from(r in Repository,
      where: r.installation_id == ^row.id and is_nil(r.removed_at),
      where: r.github_id not in ^github_ids
    )
    |> Repo.update_all(set: [removed_at: now, updated_at: now])

    row |> Ecto.Changeset.change(repos_fetched_at: fetched_at) |> Repo.update!()
  end

  defp repository_entry(repository, row, now) do
    %{
      workspace_id: row.workspace_id,
      installation_id: row.id,
      github_id: Map.fetch!(repository, "id"),
      owner: get_in(repository, ["owner", "login"]),
      name: Map.fetch!(repository, "name"),
      default_branch: repository["default_branch"] || "main",
      archived: repository["archived"] == true,
      private: repository["private"] == true,
      removed_at: nil,
      inserted_at: now,
      updated_at: now
    }
  end

  defp notify(workspace_id),
    do: Events.after_commit(Events.topic(:workspace, workspace_id), {:github_changed})
end
