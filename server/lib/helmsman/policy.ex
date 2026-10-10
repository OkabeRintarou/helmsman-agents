defmodule Helmsman.Policy do
  @moduledoc """
  The single authorization check for domain operations.

  Every domain function checks `authorize/3` before any side effect. Each
  action has its own clause; unknown actions are refused. Agents inherit
  their owner's role but can never perform management actions.
  """

  alias Helmsman.Accounts.Scope
  alias Helmsman.Actors.Actor

  @type action :: atom()

  # Every management action, listed once. Later changes reference this list
  # instead of redefining it.
  @management_actions [
    # members and invitations
    :manage_members,
    :manage_invitations,
    :create_invitation,
    :revoke_invitation,
    :change_member_role,
    :remove_member,
    :leave_workspace,
    # agent configuration, tokens, runtimes
    :manage_agents,
    :manage_tokens,
    :manage_runtimes,
    # squads and autopilots (automation)
    :manage_squads,
    :manage_autopilots,
    # GitHub connection
    :manage_github,
    # import and export
    :import_workspace,
    :export_workspace,
    # workspace settings
    :change_workspace_slug,
    :update_workspace
  ]

  # Actions with an authorization clause below.
  @actions [
    :view_workspace,
    :update_workspace,
    :change_workspace_slug,
    :rename_own_actor,
    :view_members,
    :manage_members,
    :manage_invitations,
    :create_invitation,
    :revoke_invitation,
    :change_member_role,
    :remove_member,
    :leave_workspace
  ]

  @role_rank %{owner: 4, admin: 3, member: 2, viewer: 1}

  @doc "Management actions, which agents may never perform."
  @spec management_actions() :: [action()]
  def management_actions, do: @management_actions

  @doc "Actions that have an authorization rule."
  @spec actions() :: [action()]
  def actions, do: @actions

  @doc """
  Checks whether `scope` may perform `action` on `resource`.
  """
  @spec authorize(Scope.t(), action(), term()) :: :ok | {:error, :forbidden}
  def authorize(scope, action, resource \\ nil)

  def authorize(%Scope{actor: %Actor{kind: :agent}}, action, _resource)
      when action in @management_actions,
      do: {:error, :forbidden}

  def authorize(%Scope{} = scope, :view_workspace, _resource),
    do: allow_if(role_at_least?(scope, :viewer))

  def authorize(%Scope{} = scope, :update_workspace, _resource),
    do: allow_if(role_at_least?(scope, :admin))

  def authorize(%Scope{} = scope, :change_workspace_slug, _resource),
    do: allow_if(role_at_least?(scope, :owner))

  # Viewers too may rename their own human identity.
  def authorize(%Scope{} = scope, :rename_own_actor, %Actor{} = actor),
    do: allow_if(role_at_least?(scope, :viewer) and own_human?(scope, actor))

  ## Members and invitations

  def authorize(%Scope{} = scope, :view_members, _resource),
    do: allow_if(role_at_least?(scope, :viewer))

  # Coarse checks before the rows a member operation depends on are locked;
  # the operation then authorizes the precise action below.
  def authorize(%Scope{} = scope, action, _resource)
      when action in [:manage_members, :manage_invitations],
      do: allow_if(role_at_least?(scope, :admin))

  # `role`: the role the invitation grants. Never above the inviter's own.
  def authorize(%Scope{} = scope, action, role)
      when action in [:create_invitation, :revoke_invitation],
      do: allow_if(role_at_least?(scope, :admin) and not_above_own?(scope, role))

  # Only owners touch the owner role; changing one's own role may only
  # lower it.
  def authorize(%Scope{} = scope, :change_member_role, %{from: from, to: to, self?: self?})
      when is_map_key(@role_rank, from) and is_map_key(@role_rank, to) and is_boolean(self?) do
    allow_if(
      role_at_least?(scope, :admin) and
        (scope.role == :owner or (from != :owner and to != :owner)) and
        (not self? or @role_rank[to] <= @role_rank[from])
    )
  end

  # `role`: the target's current role. Leaving is `:leave_workspace`.
  def authorize(%Scope{} = scope, :remove_member, role) when is_map_key(@role_rank, role),
    do: allow_if(role_at_least?(scope, :admin) and (scope.role == :owner or role != :owner))

  def authorize(%Scope{} = scope, :leave_workspace, _resource),
    do: allow_if(role_at_least?(scope, :viewer))

  def authorize(_scope, _action, _resource), do: {:error, :forbidden}

  defp not_above_own?(%Scope{role: own}, role)
       when is_map_key(@role_rank, own) and is_map_key(@role_rank, role),
       do: @role_rank[role] <= @role_rank[own]

  defp not_above_own?(_scope, _role), do: false

  defp own_human?(%Scope{actor: %Actor{kind: :human, id: id}, workspace: ws}, actor) do
    actor.kind == :human and actor.id == id and actor.workspace_id == ws.id
  end

  defp own_human?(_scope, _actor), do: false

  defp role_at_least?(%Scope{role: role}, min) when is_map_key(@role_rank, role),
    do: @role_rank[role] >= @role_rank[min]

  defp role_at_least?(_scope, _min), do: false

  defp allow_if(true), do: :ok
  defp allow_if(false), do: {:error, :forbidden}
end
