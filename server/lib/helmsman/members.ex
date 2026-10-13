defmodule Helmsman.Members do
  @moduledoc """
  Workspace members: listing, role changes, removal and leaving
  (designs/02 §3).

  Role changes, removals and leaving run in
  `Helmsman.Workspaces.write_transaction/5` without its shared membership
  lock. Instead they lock, in one statement ordered by id, the membership
  rows of every owner, the requester and the target `FOR UPDATE`, take the
  requester's role from the locked row and authorize again with it. The
  workspace therefore always keeps an owner, even when two owners demote
  themselves at the same time: the later one re-evaluates after the lock
  and no longer sees the other as an owner.

  After the commit the affected user's topic gets
  `{:membership_changed, workspace_id, :removed | {:role, role}}` and the
  workspace topic `{:members_changed}`.
  """

  import Ecto.Query, warn: false

  alias Helmsman.Accounts.{Scope, User}
  alias Helmsman.Actors.Actor
  alias Helmsman.ApiTokens.ApiToken
  alias Helmsman.Autopilots
  alias Helmsman.Events
  alias Helmsman.Policy
  alias Helmsman.Repo
  alias Helmsman.Workspaces
  alias Helmsman.Workspaces.{Membership, Workspace}

  @type member :: %{
          membership_id: pos_integer(),
          user_id: pos_integer(),
          display_name: String.t(),
          email: String.t(),
          actor_name: String.t(),
          role: Membership.role(),
          joined_at: DateTime.t()
        }

  @type error :: :forbidden | :not_found | :last_owner | atom()

  @doc """
  Lists the workspace's members (`:view_members`, every role), by role from
  owner down, then by display name.
  """
  @spec list(Scope.t()) :: {:ok, [member()]} | {:error, :forbidden}
  def list(%Scope{workspace: %Workspace{id: workspace_id}} = scope) do
    with :ok <- Policy.authorize(scope, :view_members) do
      members =
        Repo.all(
          from(m in Membership,
            join: u in User,
            on: u.id == m.user_id,
            join: a in Actor,
            on: a.workspace_id == m.workspace_id and a.user_id == m.user_id and a.kind == :human,
            where: m.workspace_id == ^workspace_id,
            order_by: [
              asc:
                fragment(
                  "CASE ? WHEN 'owner' THEN 0 WHEN 'admin' THEN 1 WHEN 'member' THEN 2 ELSE 3 END",
                  m.role
                ),
              asc: fragment("lower(?)", u.display_name),
              asc: m.id
            ],
            select: %{
              membership_id: m.id,
              user_id: u.id,
              display_name: u.display_name,
              email: u.email,
              actor_name: a.name,
              role: m.role,
              joined_at: m.inserted_at
            }
          )
        )

      {:ok, members}
    end
  end

  @doc """
  Changes a member's role (`:change_member_role`): admins and owners may
  change anyone's role, including their own, but only lower their own;
  only owners touch the owner role. Fails with `:last_owner` if no owner
  would be left.
  """
  @spec change_role(Scope.t(), pos_integer(), Membership.role() | String.t()) ::
          {:ok, Membership.t()} | {:error, error()}
  def change_role(%Scope{} = scope, membership_id, role) do
    with {:ok, role} <- cast_role(role) do
      Workspaces.write_transaction(
        scope,
        :manage_members,
        nil,
        &change_role_locked(&1, membership_id, role),
        membership_lock: :none
      )
    end
  end

  defp change_role_locked(scope, membership_id, role) do
    with {:ok, target_id, target_user_id} <- target_ids(scope, membership_id),
         {:ok, rows, scope} <- lock_members(scope, target_user_id),
         {:ok, target} <- find_target(rows, target_id),
         :ok <-
           Policy.authorize(scope, :change_member_role, %{
             from: target.role,
             to: role,
             self?: target.user_id == scope.user.id
           }),
         :ok <- keep_an_owner(rows, target, role) do
      update_role(target, role)
    end
  end

  defp update_role(%Membership{role: role} = membership, role), do: {:ok, membership}

  defp update_role(membership, role) do
    with {:ok, membership} <- membership |> Ecto.Changeset.change(role: role) |> Repo.update() do
      if role == :viewer,
        do: Helmsman.Daemons.cascade_member(membership.workspace_id, membership.user_id, false)

      notify(membership.workspace_id, membership.user_id, {:role, role})
      {:ok, membership}
    end
  end

  @doc """
  Removes another member (`:remove_member`; admins cannot remove owners).
  Use `leave/1` to leave yourself. See `cascade_removal/2` for what goes
  with the membership.
  """
  @spec remove(Scope.t(), pos_integer()) :: {:ok, Membership.t()} | {:error, error()}
  def remove(%Scope{} = scope, membership_id) do
    Workspaces.write_transaction(
      scope,
      :manage_members,
      nil,
      &remove_locked(&1, membership_id),
      membership_lock: :none
    )
  end

  defp remove_locked(scope, membership_id) do
    with {:ok, target_id, target_user_id} <- target_ids(scope, membership_id),
         {:ok, rows, scope} <- lock_members(scope, target_user_id),
         {:ok, target} <- find_target(rows, target_id),
         :ok <- not_self(scope, target),
         :ok <- Policy.authorize(scope, :remove_member, target.role),
         :ok <- keep_an_owner(rows, target, :removed) do
      remove_member(target)
    end
  end

  defp not_self(%Scope{user: %User{id: id}}, %Membership{user_id: id}), do: {:error, :forbidden}
  defp not_self(_scope, _target), do: :ok

  @doc """
  Leaves the scope's workspace (`:leave_workspace`, every human member).
  The last owner cannot leave.
  """
  @spec leave(Scope.t()) :: {:ok, Membership.t()} | {:error, error()}
  def leave(%Scope{} = scope) do
    Workspaces.write_transaction(scope, :leave_workspace, nil, &leave_locked/1,
      membership_lock: :none
    )
  end

  defp leave_locked(scope) do
    with {:ok, rows, scope} <- lock_members(scope, scope.user.id),
         {:ok, own} <- find_own(rows, scope),
         :ok <- Policy.authorize(scope, :leave_workspace),
         :ok <- keep_an_owner(rows, own, :removed) do
      remove_member(own)
    end
  end

  defp remove_member(membership) do
    cascade_removal(membership.workspace_id, membership.user_id)
    notify(membership.workspace_id, membership.user_id, :removed)
    {:ok, membership}
  end

  # Everything that goes when a user leaves or is removed, in the same
  # transaction. The human identity stays (history keeps the name; it is
  # reused on rejoining); the agents stay disabled until their owner
  # re-enables them; their API tokens for the workspace are revoked.
  defp cascade_removal(workspace_id, user_id) do
    now = DateTime.utc_now(:second)

    {1, _} =
      Repo.delete_all(
        from(m in Membership, where: m.workspace_id == ^workspace_id and m.user_id == ^user_id)
      )

    # After the membership row, before the identity rows (designs/01 §4,
    # `add-autopilots` decision 2).
    :ok = Autopilots.initiator_left(workspace_id, user_id)

    Repo.update_all(
      from(a in Actor,
        where: a.workspace_id == ^workspace_id and a.kind == :agent,
        where: a.owner_id == ^user_id and is_nil(a.disabled_at)
      ),
      set: [disabled_at: now, updated_at: now]
    )

    Repo.update_all(
      from(t in ApiToken,
        where: t.workspace_id == ^workspace_id and t.user_id == ^user_id,
        where: is_nil(t.revoked_at)
      ),
      set: [revoked_at: now, updated_at: now]
    )

    Helmsman.Filters.cascade_removal(workspace_id, user_id)
    Helmsman.Daemons.cascade_member(workspace_id, user_id, true)

    # Runs go last (designs/01 §4), in a fixed order so each run changes
    # once (decision 26): the runs they authorized (`unauthorized`), then
    # the queued runs of their agents, disabled above (`obsolete`), then
    # the claimed and running runs of their agents (stopped).
    Helmsman.Runs.cancel_for_initiator(workspace_id, user_id)

    own_runs =
      from(r in Helmsman.Runs.Run,
        where: r.workspace_id == ^workspace_id,
        where:
          r.agent_id in subquery(
            from(a in Actor,
              where: a.workspace_id == ^workspace_id and a.owner_id == ^user_id,
              select: a.id
            )
          )
      )

    Helmsman.Runs.cancel_pending(own_runs, :obsolete)
    Helmsman.Runs.stop_active(own_runs)

    :ok
  end

  ## Locking

  # Unlocked lookup of the target's user id, to know which rows to lock.
  defp target_ids(scope, membership_id) do
    query =
      from(m in Membership,
        where: m.workspace_id == ^scope.workspace.id and m.id == ^membership_id,
        select: {m.id, m.user_id}
      )

    case Repo.one(query) do
      nil -> {:error, :not_found}
      {id, user_id} -> {:ok, id, user_id}
    end
  end

  # One statement, ordered by id, so concurrent member operations never
  # deadlock on each other. Postgres re-checks the conditions of a row that
  # changed while waiting: an owner demoted meanwhile drops out unless they
  # are the requester or the target.
  defp lock_members(%Scope{workspace: workspace, user: user} = scope, target_user_id) do
    user_ids = Enum.uniq([user.id, target_user_id])

    rows =
      Repo.all(
        from(m in Membership,
          where: m.workspace_id == ^workspace.id,
          where: m.role == :owner or m.user_id in ^user_ids,
          order_by: m.id,
          lock: "FOR UPDATE"
        )
      )

    case Enum.find(rows, &(&1.user_id == user.id)) do
      nil -> {:error, :not_found}
      own -> {:ok, rows, %{scope | role: own.role}}
    end
  end

  defp find_own(rows, scope), do: {:ok, Enum.find(rows, &(&1.user_id == scope.user.id))}

  # The target may have left or been removed while we waited for the lock.
  defp find_target(rows, id) do
    case Enum.find(rows, &(&1.id == id)) do
      nil -> {:error, :not_found}
      target -> {:ok, target}
    end
  end

  # `rows` holds every owner, so counting them after the change is exact.
  defp keep_an_owner(rows, target, new_role) do
    owners_left =
      Enum.count(rows, fn m ->
        if m.id == target.id, do: new_role == :owner, else: m.role == :owner
      end)

    if owners_left > 0, do: :ok, else: {:error, :last_owner}
  end

  defp cast_role(role) when is_atom(role) do
    if role in Membership.roles(), do: {:ok, role}, else: {:error, :invalid_role}
  end

  defp cast_role(role) when is_binary(role) do
    case Enum.find(Membership.roles(), &(Atom.to_string(&1) == role)) do
      nil -> {:error, :invalid_role}
      role -> {:ok, role}
    end
  end

  defp notify(workspace_id, user_id, change) do
    Events.after_commit(
      Events.topic(:user, user_id),
      {:membership_changed, workspace_id, change}
    )

    Events.after_commit(Events.topic(:workspace, workspace_id), {:members_changed})
  end
end
