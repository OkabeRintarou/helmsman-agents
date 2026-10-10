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

  # {action, role, actor_kind, resource_fun, expected}. Later changes append
  # their rows here.
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
            end
          ]
          |> List.flatten()

  defp scope(role, kind) do
    actor = if kind == :agent, do: @agent, else: @human

    %Scope{user: @user, workspace: @workspace, role: role, actor: actor, via: :web}
  end

  for {action, role, kind, resource_fun, expected} <- @matrix do
    @tag action: action
    test "#{action} by #{role} #{kind} via #{inspect(resource_fun)} → #{expected}" do
      scope = scope(unquote(role), unquote(kind))
      resource = unquote(resource_fun).(scope)
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

  test "unknown actions and scopes without a role are refused" do
    assert Policy.authorize(scope(:owner, :human), :launch_rockets) == {:error, :forbidden}
    assert Policy.authorize(%Scope{user: @user}, :view_workspace) == {:error, :forbidden}
  end
end
