defmodule Helmsman.PolicyMatrixTest do
  use ExUnit.Case, async: true

  alias Helmsman.Accounts.{Scope, User}
  alias Helmsman.Actors.Actor
  alias Helmsman.Policy
  alias Helmsman.Workspaces.Workspace

  @workspace %Workspace{id: 1, slug: "acme", name: "Acme"}
  @user %User{id: 10}
  @human %Actor{id: 100, workspace_id: 1, kind: :human, user_id: 10}
  @agent %Actor{id: 200, workspace_id: 1, kind: :agent, owner_id: 10}

  # Resource builders: `fn scope -> resource end`.
  @none &__MODULE__.no_resource/1
  @own_actor &__MODULE__.own_actor/1
  @other_human &__MODULE__.other_human/1
  @system_actor &__MODULE__.system_actor/1

  def no_resource(_scope), do: nil
  def own_actor(scope), do: scope.actor
  def other_human(_scope), do: %Actor{id: 101, workspace_id: 1, kind: :human, user_id: 11}
  def system_actor(_scope), do: %Actor{id: 102, workspace_id: 1, kind: :system, name: "helmsman"}

  @roles [:owner, :admin, :member, :viewer]
  @rank %{owner: 4, admin: 3, member: 2, viewer: 1}

  # {action, role, actor_kind, resource, expected}; `resource` is a value or
  # a builder `fn scope -> resource end`. Later changes append their rows
  # here.
  @matrix [
            # view_workspace: everyone, humans and agents
            for role <- [:owner, :admin, :member, :viewer], kind <- [:human, :agent] do
              {:view_workspace, role, kind, @none, :ok}
            end,
            # update_workspace: owner and admin humans; agents never
            for role <- [:owner, :admin, :member, :viewer], kind <- [:human, :agent] do
              expected = if kind == :human and role in [:owner, :admin], do: :ok, else: :forbidden
              {:update_workspace, role, kind, @none, expected}
            end,
            # change_workspace_slug: owner humans only
            for role <- [:owner, :admin, :member, :viewer], kind <- [:human, :agent] do
              expected = if kind == :human and role == :owner, do: :ok, else: :forbidden
              {:change_workspace_slug, role, kind, @none, expected}
            end,
            # rename_own_actor: every role, only the scope's own human identity
            for role <- [:owner, :admin, :member, :viewer] do
              [
                {:rename_own_actor, role, :human, @own_actor, :ok},
                {:rename_own_actor, role, :human, @other_human, :forbidden},
                {:rename_own_actor, role, :human, @system_actor, :forbidden},
                {:rename_own_actor, role, :agent, @own_actor, :forbidden}
              ]
            end,
            # view_members: everyone, humans and agents
            for role <- @roles, kind <- [:human, :agent] do
              {:view_members, role, kind, @none, :ok}
            end,
            # manage_members, manage_invitations (coarse checks before
            # locking): owner and admin humans
            for action <- [:manage_members, :manage_invitations],
                role <- @roles,
                kind <- [:human, :agent] do
              expected = if kind == :human and role in [:owner, :admin], do: :ok, else: :forbidden
              {action, role, kind, @none, expected}
            end,
            # create_invitation, revoke_invitation: owner and admin humans,
            # for an invitation role not above their own
            for action <- [:create_invitation, :revoke_invitation],
                role <- @roles,
                kind <- [:human, :agent],
                target <- @roles do
              expected =
                if kind == :human and role in [:owner, :admin] and @rank[target] <= @rank[role],
                  do: :ok,
                  else: :forbidden

              {action, role, kind, target, expected}
            end,
            for action <- [:create_invitation, :revoke_invitation] do
              {action, :owner, :human, @none, :forbidden}
            end,
            # change_member_role on someone else: owners anything; admins
            # neither to nor from owner
            for role <- @roles, from <- @roles, to <- @roles do
              expected =
                cond do
                  role == :owner -> :ok
                  role == :admin and from != :owner and to != :owner -> :ok
                  true -> :forbidden
                end

              {:change_member_role, role, :human, %{from: from, to: to, self?: false}, expected}
            end,
            # change_member_role on oneself: owners and admins may only lower
            # (or keep) their role
            for role <- @roles, to <- @roles do
              expected =
                if role in [:owner, :admin] and @rank[to] <= @rank[role],
                  do: :ok,
                  else: :forbidden

              {:change_member_role, role, :human, %{from: role, to: to, self?: true}, expected}
            end,
            for role <- @roles do
              {:change_member_role, role, :agent, %{from: :viewer, to: :viewer, self?: false},
               :forbidden}
            end,
            {:change_member_role, :owner, :human, @none, :forbidden},
            # remove_member: owners anyone; admins anyone but owners
            for role <- @roles, kind <- [:human, :agent], target <- @roles do
              expected =
                cond do
                  kind == :agent -> :forbidden
                  role == :owner -> :ok
                  role == :admin and target != :owner -> :ok
                  true -> :forbidden
                end

              {:remove_member, role, kind, target, expected}
            end,
            {:remove_member, :owner, :human, @none, :forbidden},
            # leave_workspace: every human; agents never
            for role <- @roles, kind <- [:human, :agent] do
              {:leave_workspace, role, kind, @none, if(kind == :human, do: :ok, else: :forbidden)}
            end
          ]
          |> List.flatten()

  defp resolve(builder, scope) when is_function(builder, 1), do: builder.(scope)
  defp resolve(resource, _scope), do: resource

  defp scope(role, kind) do
    actor = if kind == :agent, do: @agent, else: @human

    %Scope{user: @user, workspace: @workspace, role: role, actor: actor, via: :web}
  end

  for {action, role, kind, resource, expected} <- @matrix do
    @resource resource
    @tag action: action
    test "#{action} by #{role} #{kind} via #{inspect(resource)} → #{expected}" do
      scope = scope(unquote(role), unquote(kind))
      resource = resolve(@resource, scope)
      expected = if unquote(expected) == :ok, do: :ok, else: {:error, :forbidden}

      assert Policy.authorize(scope, unquote(action), resource) == expected
    end
  end

  test "every action with a rule is covered by the matrix" do
    covered = @matrix |> Enum.map(&elem(&1, 0)) |> MapSet.new()
    assert MapSet.new(Policy.actions()) == covered
  end

  test "agents are refused every management action, whatever the role" do
    for action <- Policy.management_actions(), role <- [:owner, :admin, :member, :viewer] do
      assert Policy.authorize(scope(role, :agent), action) == {:error, :forbidden},
             "#{action} by #{role} agent"
    end
  end

  describe "member role changes from the spec" do
    defp change(role, from, to, self?) do
      Policy.authorize(scope(role, :human), :change_member_role, %{
        from: from,
        to: to,
        self?: self?
      })
    end

    test "owner promotes an admin to owner",
      do: assert(change(:owner, :admin, :owner, false) == :ok)

    test "admin demotes an owner",
      do: assert(change(:admin, :owner, :member, false) == {:error, :forbidden})

    test "admin demotes themselves", do: assert(change(:admin, :admin, :member, true) == :ok)

    test "admin makes themselves owner",
      do: assert(change(:admin, :admin, :owner, true) == {:error, :forbidden})

    test "member makes themselves viewer",
      do: assert(change(:member, :member, :viewer, true) == {:error, :forbidden})

    test "owner demotes themselves (the last-owner rule is checked by Members)",
      do: assert(change(:owner, :owner, :admin, true) == :ok)
  end

  test "unknown actions and scopes without a role are refused" do
    assert Policy.authorize(scope(:owner, :human), :launch_rockets) == {:error, :forbidden}
    assert Policy.authorize(%Scope{user: @user}, :view_workspace) == {:error, :forbidden}
  end
end
