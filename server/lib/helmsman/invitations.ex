defmodule Helmsman.Invitations do
  @moduledoc """
  Invitations: one-time links to join a workspace (designs/02 §3).

  The token is returned to the inviter once; only its SHA-256 hash is
  stored. Every reason an invitation cannot be used (unknown, expired,
  revoked, accepted) is reported as `:invalid_invitation`.
  """

  import Ecto.Query, warn: false

  require Logger

  alias Helmsman.Accounts.{Scope, User}
  alias Helmsman.Actors
  alias Helmsman.Events
  alias Helmsman.Invitations.{Invitation, InvitationNotifier}
  alias Helmsman.Locks
  alias Helmsman.Policy
  alias Helmsman.Repo
  alias Helmsman.Tx
  alias Helmsman.Workspaces
  alias Helmsman.Workspaces.{Membership, Workspace}

  @token_bytes 32

  @type preview :: %{
          workspace_name: String.t(),
          inviter_name: String.t(),
          role: Membership.role(),
          email_bound?: boolean(),
          expires_at: DateTime.t()
        }

  ## Creating

  @doc """
  Creates an invitation (`:create_invitation`; the role may not be above
  the inviter's own).

  `attrs` takes `email` (blank = a generic link) and `role`. `invite_url`
  builds the invitation link from the token, e.g.
  `&url(~p"/invite/\#{&1}")`; when the invitation is bound to an email, the
  link is mailed there after the commit. A failed delivery is logged and
  does not undo the invitation.

  Returns the invitation and the token, which is never available again.
  """
  @spec create(Scope.t(), map(), (String.t() -> String.t())) ::
          {:ok, %{invitation: Invitation.t(), token: String.t()}}
          | {:error, Ecto.Changeset.t() | :forbidden | :not_found | atom()}
  def create(
        %Scope{workspace: %Workspace{} = workspace, user: %User{} = inviter} = scope,
        attrs,
        invite_url
      )
      when is_function(invite_url, 1) do
    token = generate_token()

    changeset =
      Invitation.create_changeset(
        %Invitation{
          workspace_id: workspace.id,
          invited_by_id: inviter.id,
          token_hash: hash_token(token),
          expires_at: expires_at()
        },
        attrs
      )

    case Ecto.Changeset.get_field(changeset, :role) do
      # Without a valid role there is nothing to authorize or insert.
      nil ->
        {:error, %{changeset | action: :insert}}

      role ->
        Workspaces.write_transaction(scope, :create_invitation, role, fn scope ->
          insert_invitation(scope, changeset, token, invite_url)
        end)
    end
  end

  defp insert_invitation(scope, changeset, token, invite_url) do
    with {:ok, invitation} <- Repo.insert(changeset) do
      invitation = %{invitation | workspace: scope.workspace, invited_by: scope.user}

      if invitation.email, do: deliver_after_commit(invitation, token, invite_url)
      {:ok, %{invitation: invitation, token: token}}
    end
  end

  defp deliver_after_commit(invitation, token, invite_url),
    do: Tx.after_commit(fn -> deliver_invitation(invitation, invite_url.(token)) end)

  defp deliver_invitation(invitation, url) do
    case InvitationNotifier.deliver_invitation(invitation, url) do
      {:ok, _email} ->
        :ok

      {:error, reason} ->
        Logger.error(
          "failed to deliver invitation #{invitation.id} to #{invitation.email}: " <>
            inspect(reason)
        )
    end
  end

  defp generate_token,
    do: @token_bytes |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

  @doc false
  @spec hash_token(String.t()) :: binary()
  def hash_token(token) when is_binary(token), do: :crypto.hash(:sha256, token)

  defp expires_at do
    days = Application.fetch_env!(:helmsman, :invitation_ttl_days)
    DateTime.add(DateTime.utc_now(:second), days, :day)
  end

  ## Listing and revoking

  @doc """
  Lists the workspace's invitations that are neither accepted, revoked nor
  expired, newest first, with the inviter loaded (`:manage_invitations`).
  """
  @spec list_pending(Scope.t()) :: {:ok, [Invitation.t()]} | {:error, :forbidden}
  def list_pending(%Scope{workspace: %Workspace{id: workspace_id}} = scope) do
    with :ok <- Policy.authorize(scope, :manage_invitations) do
      now = DateTime.utc_now()

      invitations =
        Repo.all(
          from(i in Invitation,
            where: i.workspace_id == ^workspace_id,
            where: is_nil(i.accepted_at) and is_nil(i.revoked_at) and i.expires_at > ^now,
            order_by: [desc: i.inserted_at, desc: i.id],
            preload: [:invited_by]
          )
        )

      {:ok, invitations}
    end
  end

  @doc """
  Revokes an invitation of the workspace (`:revoke_invitation`; its role
  may not be above the requester's own). It stops working at once.

  Returns `{:error, :invalid_invitation}` if it was already accepted or
  revoked.
  """
  @spec revoke(Scope.t(), pos_integer()) ::
          {:ok, Invitation.t()}
          | {:error, :forbidden | :not_found | :invalid_invitation | atom()}
  def revoke(%Scope{workspace: %Workspace{}} = scope, invitation_id) do
    Workspaces.write_transaction(
      scope,
      :manage_invitations,
      nil,
      &revoke_locked(&1, invitation_id)
    )
  end

  defp revoke_locked(scope, invitation_id) do
    query =
      from(i in Invitation,
        where: i.workspace_id == ^scope.workspace.id and i.id == ^invitation_id,
        lock: "FOR UPDATE"
      )

    with {:ok, invitation} <- fetch(query),
         :ok <- Policy.authorize(scope, :revoke_invitation, invitation.role),
         :ok <- unused(invitation) do
      invitation
      |> Ecto.Changeset.change(
        revoked_at: DateTime.utc_now(:second),
        revoked_by_id: scope.user.id
      )
      |> Repo.update()
    end
  end

  defp fetch(query) do
    case Repo.one(query) do
      nil -> {:error, :not_found}
      record -> {:ok, record}
    end
  end

  defp unused(%Invitation{accepted_at: nil, revoked_at: nil}), do: :ok
  defp unused(%Invitation{}), do: {:error, :invalid_invitation}

  ## Previewing

  @doc """
  Returns what the holder of `token` may see before accepting: workspace
  name, inviter, role, whether an email is bound (never the email itself)
  and the expiry.

  Unknown, expired, revoked and accepted tokens all return
  `{:error, :invalid_invitation}`.
  """
  @spec preview(String.t()) :: {:ok, preview()} | {:error, :invalid_invitation}
  def preview(token) when is_binary(token) do
    query =
      from(i in valid_query(token),
        join: w in assoc(i, :workspace),
        join: u in assoc(i, :invited_by),
        select: %{
          workspace_name: w.name,
          inviter_name: u.display_name,
          role: i.role,
          email_bound?: not is_nil(i.email),
          expires_at: i.expires_at
        }
      )

    case Repo.one(query) do
      nil -> {:error, :invalid_invitation}
      preview -> {:ok, preview}
    end
  end

  def preview(_token), do: {:error, :invalid_invitation}

  @doc """
  Checks, without locking or consuming it, that `token` is a valid
  invitation `email` may register with: a generic link, or one bound to
  that email.
  """
  @spec check_signup(String.t(), String.t()) :: :ok | {:error, :invalid_invitation}
  def check_signup(token, email) when is_binary(token) and is_binary(email) do
    case Repo.one(from(i in valid_query(token), select: {i.id, i.email})) do
      nil ->
        {:error, :invalid_invitation}

      {_id, bound} ->
        if is_nil(bound) or bound == Invitation.normalize_email(email),
          do: :ok,
          else: {:error, :invalid_invitation}
    end
  end

  defp valid_query(token) do
    hash = hash_token(token)
    now = DateTime.utc_now()

    from(i in Invitation,
      where: i.token_hash == ^hash,
      where: is_nil(i.accepted_at) and is_nil(i.revoked_at) and i.expires_at > ^now
    )
  end

  ## Accepting

  @doc """
  Lets `user` join the invitation's workspace with its role, together with
  their human identity (reused if they were a member before).

  Only `user.id` is used: the email and its confirmation are re-read from
  the database, locked `FOR SHARE`, so an email change that is in progress
  either commits first or waits. The invitation row is locked
  `FOR UPDATE`, so of concurrent accepts only one succeeds.

  Errors other than `:invalid_invitation` leave the invitation usable:
  `:email_mismatch` (bound to another email), `:email_unconfirmed` and
  `:already_member`.

  After the commit `{:members_changed}` is broadcast on the workspace topic.
  """
  @spec accept(User.t(), String.t()) ::
          {:ok, Workspaces.access()}
          | {:error,
             :invalid_invitation
             | :email_mismatch
             | :email_unconfirmed
             | :already_member
             | :name_unavailable
             | Ecto.Changeset.t()
             | atom()}
  def accept(%User{id: user_id}, token) when is_binary(token) do
    Tx.run(
      fn ->
        with {:ok, workspace_id} <- invitation_workspace_id(token),
             :ok <- Locks.maint_shared!(workspace_id),
             {:ok, invitation} <- lock_valid_invitation(token),
             {:ok, user} <- lock_user(user_id),
             :ok <- still_unexpired(invitation),
             :ok <- check_email(invitation, user),
             :ok <- check_not_member(workspace_id, user_id) do
          join(invitation, user)
        end
      end,
      retry: 1
    )
  end

  # Unlocked lookup to know which maintenance lock to take first.
  defp invitation_workspace_id(token) do
    case Repo.one(
           from(i in Invitation,
             where: i.token_hash == ^hash_token(token),
             select: i.workspace_id
           )
         ) do
      nil -> {:error, :invalid_invitation}
      workspace_id -> {:ok, workspace_id}
    end
  end

  # A concurrent accept that commits first makes Postgres re-check the
  # conditions on the new row version, which then no longer matches.
  defp lock_valid_invitation(token) do
    case Repo.one(lock(valid_query(token), "FOR UPDATE")) do
      nil -> {:error, :invalid_invitation}
      invitation -> {:ok, invitation}
    end
  end

  defp lock_user(user_id) do
    case Repo.one(from(u in User, where: u.id == ^user_id, lock: "FOR SHARE")) do
      nil -> {:error, :not_found}
      user -> {:ok, user}
    end
  end

  # The lock waits above may outlast the expiry, and the queries compared
  # against the time they were built: check again with the current time once
  # every lock is held.
  defp still_unexpired(%Invitation{expires_at: expires_at}) do
    if DateTime.after?(expires_at, DateTime.utc_now()),
      do: :ok,
      else: {:error, :invalid_invitation}
  end

  defp check_email(%Invitation{email: nil}, _user), do: :ok

  defp check_email(%Invitation{email: email}, %User{} = user) do
    cond do
      Invitation.normalize_email(user.email) != email -> {:error, :email_mismatch}
      is_nil(user.confirmed_at) -> {:error, :email_unconfirmed}
      true -> :ok
    end
  end

  defp check_not_member(workspace_id, user_id) do
    if Repo.exists?(
         from(m in Membership, where: m.workspace_id == ^workspace_id and m.user_id == ^user_id)
       ),
       do: {:error, :already_member},
       else: :ok
  end

  defp join(invitation, user) do
    now = DateTime.utc_now(:second)

    {1, _} =
      Repo.update_all(from(i in Invitation, where: i.id == ^invitation.id),
        set: [accepted_at: now, accepted_by_id: user.id, updated_at: now]
      )

    workspace = Repo.get!(Workspace, invitation.workspace_id)

    with {:ok, membership} <- insert_membership(workspace, user, invitation.role),
         {:ok, actor} <- Actors.ensure_human(workspace, user) do
      Events.after_commit(Events.topic(:workspace, workspace.id), {:members_changed})
      {:ok, %{workspace: workspace, membership: membership, actor: actor}}
    end
  end

  # The unique index backs up check_not_member/2 against a concurrent
  # join; the error rolls the transaction back, leaving the invitation
  # unused.
  defp insert_membership(workspace, user, role) do
    %Membership{workspace_id: workspace.id, user_id: user.id}
    |> Membership.changeset(%{role: role})
    |> Repo.insert()
    |> case do
      {:ok, membership} ->
        {:ok, membership}

      {:error, changeset} ->
        {:error, membership_error(changeset)}
    end
  end

  defp membership_error(%Ecto.Changeset{errors: errors} = changeset) do
    case errors[:workspace_id] do
      {_message, opts} -> if opts[:constraint] == :unique, do: :already_member, else: changeset
      nil -> changeset
    end
  end
end
