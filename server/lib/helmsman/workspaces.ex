defmodule Helmsman.Workspaces do
  @moduledoc """
  Workspaces, memberships and the write transaction every workspace write
  goes through.
  """

  import Ecto.Query, warn: false

  alias Helmsman.Accounts.{Scope, User}
  alias Helmsman.Actors
  alias Helmsman.Actors.Actor
  alias Helmsman.Events
  alias Helmsman.Locks
  alias Helmsman.Policy
  alias Helmsman.Repo
  alias Helmsman.Runs.RunTokens
  alias Helmsman.Tx
  alias Helmsman.Workspaces.{Membership, Workspace}

  @type access :: %{workspace: Workspace.t(), membership: Membership.t(), actor: Actor.t()}

  ## Creating

  @doc """
  Creates a workspace owned by `user`.

  In one transaction: the workspace, the owner membership, the user's human
  identity and the system identity `helmsman`.
  """
  @spec create(User.t(), map()) :: {:ok, Workspace.t()} | {:error, Ecto.Changeset.t() | atom()}
  def create(%User{} = user, attrs) do
    Tx.run(fn -> create_in_transaction(user, attrs) end)
  end

  @doc """
  Same as `create/2`, for callers that already run a transaction (for
  example the first user's registration).
  """
  @spec create_in_transaction(User.t(), map()) ::
          {:ok, Workspace.t()} | {:error, Ecto.Changeset.t() | atom()}
  def create_in_transaction(%User{} = user, attrs) do
    Tx.run(fn ->
      with {:ok, workspace} <- %Workspace{} |> Workspace.changeset(attrs) |> Repo.insert(),
           {:ok, _membership} <- insert_membership(workspace, user, :owner),
           {:ok, _human} <- Actors.ensure_human(workspace, user),
           {:ok, _system} <- Actors.ensure_system(workspace) do
        {:ok, workspace}
      end
    end)
  end

  defp insert_membership(workspace, user, role) do
    %Membership{workspace_id: workspace.id, user_id: user.id}
    |> Membership.changeset(%{role: role})
    |> Repo.insert()
  end

  ## Reading

  @doc """
  Returns the workspace with `slug` together with the user's membership and
  human identity there.

  Unknown slugs and workspaces the user is not a member of both return
  `{:error, :not_found}`.
  """
  @spec fetch_for_user(User.t(), String.t()) :: {:ok, access()} | {:error, :not_found}
  def fetch_for_user(%User{id: user_id}, slug) when is_binary(slug) do
    query =
      from(w in Workspace,
        join: m in Membership,
        on: m.workspace_id == w.id and m.user_id == ^user_id,
        join: a in Actor,
        on: a.workspace_id == w.id and a.user_id == ^user_id and a.kind == :human,
        where: w.slug == ^String.downcase(slug),
        select: %{workspace: w, membership: m, actor: a}
      )

    case Repo.one(query) do
      nil -> {:error, :not_found}
      access -> {:ok, access}
    end
  end

  @doc """
  Lists the workspaces `user` belongs to with the role in each, ordered by
  name.
  """
  @spec list_for_user(User.t()) :: [%{workspace: Workspace.t(), role: Membership.role()}]
  def list_for_user(%User{id: user_id}) do
    Repo.all(
      from(w in Workspace,
        join: m in Membership,
        on: m.workspace_id == w.id and m.user_id == ^user_id,
        order_by: [asc: fragment("lower(?)", w.name), asc: w.name, asc: w.id],
        select: %{workspace: w, role: m.role}
      )
    )
  end

  @doc "Gets a workspace by id, or nil."
  @spec get(integer()) :: Workspace.t() | nil
  def get(id) when is_integer(id), do: Repo.get(Workspace, id)

  @doc "Gets a workspace by slug, or nil."
  @spec get_by_slug(String.t()) :: Workspace.t() | nil
  def get_by_slug(slug) when is_binary(slug),
    do: Repo.get_by(Workspace, slug: String.downcase(slug))

  @doc "Gets a user's membership of a workspace, or nil."
  @spec get_membership(pos_integer(), pos_integer()) :: Membership.t() | nil
  def get_membership(workspace_id, user_id),
    do: Repo.get_by(Membership, workspace_id: workspace_id, user_id: user_id)

  ## Updating

  @doc """
  Changes the workspace name (`:update_workspace`, owner or admin) and/or
  slug (`:change_workspace_slug`, owner only).

  After the commit `{:workspace_updated, %{id, name, slug}}` is broadcast on
  `Helmsman.Events.topic(:workspace, id)`.
  """
  @spec update(Scope.t(), map()) ::
          {:ok, Workspace.t()} | {:error, Ecto.Changeset.t() | :forbidden | :not_found | atom()}
  def update(%Scope{workspace: %Workspace{}} = scope, attrs) do
    # The outer check covers the name; a slug change is authorized again
    # below with the role re-read inside the transaction.
    write_transaction(scope, :update_workspace, fn scope ->
      workspace =
        Repo.one!(from(w in Workspace, where: w.id == ^scope.workspace.id, lock: "FOR UPDATE"))

      changeset = Workspace.changeset(workspace, attrs)

      with :ok <- authorize_changes(scope, changeset) do
        update_workspace(changeset)
      end
    end)
  end

  defp authorize_changes(scope, changeset) do
    if Ecto.Changeset.changed?(changeset, :slug),
      do: Policy.authorize(scope, :change_workspace_slug),
      else: :ok
  end

  defp update_workspace(%Ecto.Changeset{valid?: true, changes: changes} = changeset)
       when changes == %{},
       do: {:ok, changeset.data}

  defp update_workspace(changeset) do
    with {:ok, workspace} <- Repo.update(changeset) do
      Events.after_commit(
        Events.topic(:workspace, workspace.id),
        {:workspace_updated, %{id: workspace.id, name: workspace.name, slug: workspace.slug}}
      )

      {:ok, workspace}
    end
  end

  ## Write transaction

  @doc """
  Runs a workspace write.

  Inside `Helmsman.Tx.run/2`: takes the workspace maintenance lock (shared),
  re-reads the requester's membership `FOR SHARE` (gone →
  `{:error, :not_found}`; otherwise the scope gets the current role),
  authorizes `action` on `resource` with `Helmsman.Policy` and calls
  `fun.(scope)`, which returns `{:ok, value}` or `{:error, reason}`. For a
  run scope, the run is checked again last
  (`Helmsman.Runs.RunTokens.lock_active/1`): ended → `{:error, :run_ended}`
  and the write rolls back.

  The shared row lock serializes the write with role changes and member
  removals, which lock the membership row `FOR UPDATE`.

  As the outermost transaction, a deadlock or serialization failure is
  retried once (`Helmsman.Tx.run/2` with `retry: 1`); a second failure
  returns `{:error, code}`. Callbacks registered with
  `Helmsman.Events.after_commit/2` run once, after the commit, and are never
  part of a retry.

  ## Options

    * `:membership_lock` - `:none` skips the `FOR SHARE` lock; member
      management locks the membership rows itself inside `fun`.
  """
  @spec write_transaction(
          Scope.t(),
          Policy.action(),
          term(),
          (Scope.t() -> Tx.result()),
          keyword()
        ) :: Tx.result()
  def write_transaction(%Scope{} = scope, action, resource \\ nil, fun, opts \\ [])
      when is_function(fun, 1) do
    Tx.run(fn -> locked_write(scope, action, resource, fun, opts) end, retry: 1)
  end

  defp locked_write(%Scope{workspace: workspace, user: user} = scope, action, resource, fun, opts) do
    Locks.maint_shared!(workspace.id)

    query =
      from(m in Membership, where: m.workspace_id == ^workspace.id and m.user_id == ^user.id)

    query =
      case Keyword.get(opts, :membership_lock, :share) do
        :none -> query
        :share -> lock(query, "FOR SHARE")
      end

    case Repo.one(query) do
      nil ->
        {:error, :not_found}

      %Membership{role: role} ->
        scope = %{scope | role: role}

        with :ok <- Policy.authorize(scope, action, resource),
             {:ok, _value} = result <- fun.(scope),
             :ok <- RunTokens.lock_active(scope) do
          result
        end
    end
  end
end
