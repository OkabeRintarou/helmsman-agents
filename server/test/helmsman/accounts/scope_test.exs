defmodule Helmsman.Accounts.ScopeTest do
  use ExUnit.Case, async: true

  alias Helmsman.Accounts.{Scope, User}
  alias Helmsman.Actors.Actor
  alias Helmsman.Workspaces.{Membership, Workspace}

  test "for_user/1 keeps the generated behaviour" do
    user = %User{id: 1}

    assert %Scope{user: ^user, workspace: nil, role: nil, actor: nil, via: nil, run: nil} =
             Scope.for_user(user)

    assert Scope.for_user(nil) == nil
  end

  test "put_workspace/4 sets the workspace, the membership's role and the actor" do
    user = %User{id: 1}
    workspace = %Workspace{id: 2, slug: "acme", name: "Acme"}
    membership = %Membership{workspace_id: 2, user_id: 1, role: :admin}
    actor = %Actor{id: 3, workspace_id: 2, kind: :human, user_id: 1, name: "alice"}

    scope = user |> Scope.for_user() |> Scope.put_workspace(workspace, membership, actor)

    assert %Scope{user: ^user, workspace: ^workspace, role: :admin, actor: ^actor} = scope
    assert scope.via == nil
    assert scope.run == nil
  end
end
