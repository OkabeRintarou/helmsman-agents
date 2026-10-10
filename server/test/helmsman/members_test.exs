defmodule Helmsman.MembersTest do
  use Helmsman.DataCase, async: true

  import Helmsman.AccountsFixtures
  import Helmsman.WorkspacesFixtures

  alias Helmsman.Actors
  alias Helmsman.Actors.Actor
  alias Helmsman.Events
  alias Helmsman.Invitations
  alias Helmsman.Members
  alias Helmsman.Workspaces

  setup do
    owner = user_fixture(%{display_name: "Olivia"})
    workspace = workspace_fixture(owner)
    %{owner: owner, workspace: workspace, owner_scope: workspace_scope_fixture(owner, workspace)}
  end

  # Adds a user with `role`; returns {scope, membership}.
  defp add_member(workspace, role, attrs \\ %{}) do
    user = user_fixture(attrs)
    membership = member_fixture(workspace, user, role)
    {workspace_scope_fixture(user, workspace), membership}
  end

  defp role_of(workspace, user), do: Workspaces.get_membership(workspace.id, user.id).role

  defp agent!(workspace, owner, name) do
    Repo.insert!(%Actor{workspace_id: workspace.id, kind: :agent, name: name, owner_id: owner.id})
  end

  defp subscribe(workspace, user) do
    Events.subscribe(Events.topic(:user, user.id))
    Events.subscribe(Events.topic(:workspace, workspace.id))
  end

  describe "list/1" do
    test "a viewer sees every member, by role then display name",
         %{workspace: workspace, owner: owner} do
      {_, _} = add_member(workspace, :member, %{display_name: "zed"})
      {_, _} = add_member(workspace, :admin, %{display_name: "Bob"})
      {_, _} = add_member(workspace, :member, %{display_name: "amy"})
      {viewer, viewer_membership} = add_member(workspace, :viewer, %{display_name: "Vic"})

      assert {:ok, members} = Members.list(viewer)

      assert Enum.map(members, &{&1.display_name, &1.role}) == [
               {"Olivia", :owner},
               {"Bob", :admin},
               {"amy", :member},
               {"zed", :member},
               {"Vic", :viewer}
             ]

      vic = List.last(members)
      assert vic.membership_id == viewer_membership.id
      assert vic.user_id == viewer.user.id
      assert vic.email == viewer.user.email
      assert vic.actor_name == viewer.actor.name
      assert vic.joined_at == viewer_membership.inserted_at

      assert hd(members).email == owner.email
    end
  end

  describe "change_role/3" do
    test "owner promotes an admin to owner", %{workspace: ws, owner_scope: owner} do
      {bob, bob_m} = add_member(ws, :admin)
      assert {:ok, %{role: :owner}} = Members.change_role(owner, bob_m.id, :owner)
      assert role_of(ws, bob.user) == :owner
    end

    test "admin may change members and admins but not to or from owner",
         %{workspace: ws, owner: owner} do
      {admin, _} = add_member(ws, :admin)
      {member, member_m} = add_member(ws, :member)
      owner_m = Workspaces.get_membership(ws.id, owner.id)

      assert {:ok, _} = Members.change_role(admin, member_m.id, "admin")
      assert role_of(ws, member.user) == :admin
      assert {:ok, _} = Members.change_role(admin, member_m.id, :viewer)

      assert {:error, :forbidden} = Members.change_role(admin, owner_m.id, :member)
      assert {:error, :forbidden} = Members.change_role(admin, member_m.id, :owner)
      assert role_of(ws, owner) == :owner
      assert role_of(ws, member.user) == :viewer
    end

    test "admin demotes themselves", %{workspace: ws} do
      {admin, admin_m} = add_member(ws, :admin)
      assert {:ok, %{role: :member}} = Members.change_role(admin, admin_m.id, :member)
    end

    test "admin cannot make themselves owner", %{workspace: ws} do
      {admin, admin_m} = add_member(ws, :admin)
      assert {:error, :forbidden} = Members.change_role(admin, admin_m.id, :owner)
      assert role_of(ws, admin.user) == :admin
    end

    test "members and viewers cannot change any role, not even their own",
         %{workspace: ws, owner: owner} do
      owner_m = Workspaces.get_membership(ws.id, owner.id)

      for role <- [:member, :viewer] do
        {scope, own} = add_member(ws, role)
        assert {:error, :forbidden} = Members.change_role(scope, own.id, :viewer)
        assert {:error, :forbidden} = Members.change_role(scope, owner_m.id, :viewer)
      end
    end

    test "the only owner cannot demote themselves", %{workspace: ws, owner: owner} do
      owner_scope = workspace_scope_fixture(owner, ws)
      owner_m = Workspaces.get_membership(ws.id, owner.id)

      assert {:error, :last_owner} = Members.change_role(owner_scope, owner_m.id, :admin)
      assert role_of(ws, owner) == :owner
    end

    test "one of two owners may demote themselves", %{workspace: ws, owner: owner} do
      {_bob, _} = add_member(ws, :owner)
      owner_m = Workspaces.get_membership(ws.id, owner.id)

      assert {:ok, _} =
               Members.change_role(workspace_scope_fixture(owner, ws), owner_m.id, :admin)
    end

    test "the role is re-read inside the transaction", %{workspace: ws} do
      {admin, _} = add_member(ws, :admin)
      {_member, member_m} = add_member(ws, :member)

      # The scope still says admin; the database says viewer.
      Workspaces.get_membership(ws.id, admin.user.id)
      |> Ecto.Changeset.change(role: :viewer)
      |> Repo.update!()

      assert {:error, :forbidden} = Members.change_role(admin, member_m.id, :viewer)
    end

    test "unknown roles and memberships", %{owner_scope: owner, owner: owner_user} do
      other = workspace_fixture(owner_user)
      other_m = Workspaces.get_membership(other.id, owner_user.id)

      assert {:error, :invalid_role} = Members.change_role(owner, other_m.id, :guest)
      assert {:error, :invalid_role} = Members.change_role(owner, other_m.id, "guest")
      assert {:error, :not_found} = Members.change_role(owner, other_m.id, :viewer)
      assert role_of(other, owner_user) == :owner
    end
  end

  describe "remove/2" do
    test "removing a member disables their agents and keeps their human identity",
         %{workspace: ws, owner: owner} do
      {admin, _} = add_member(ws, :admin)
      {bob, bob_m} = add_member(ws, :member)
      agents = [agent!(ws, bob.user, "bob-bot-1"), agent!(ws, bob.user, "bob-bot-2")]
      owners_agent = agent!(ws, owner, "olivia-bot")
      elsewhere = workspace_fixture(bob.user)
      other_agent = agent!(elsewhere, bob.user, "bob-bot-1")

      assert {:ok, removed} = Members.remove(admin, bob_m.id)
      assert removed.id == bob_m.id

      refute Workspaces.get_membership(ws.id, bob.user.id)
      assert {:error, :not_found} = Workspaces.fetch_for_user(bob.user, ws.slug)
      assert Enum.all?(agents, &Repo.reload!(&1).disabled_at)
      refute Repo.reload!(owners_agent).disabled_at
      refute Repo.reload!(other_agent).disabled_at

      human = Actors.get_human(ws.id, bob.user.id)
      assert human.id == bob.actor.id
      refute human.disabled_at
    end

    test "admin cannot remove an owner; owner can remove another owner",
         %{workspace: ws, owner_scope: owner} do
      {admin, _} = add_member(ws, :admin)
      {other_owner, other_owner_m} = add_member(ws, :owner)

      assert {:error, :forbidden} = Members.remove(admin, other_owner_m.id)
      assert role_of(ws, other_owner.user) == :owner

      assert {:ok, _} = Members.remove(owner, other_owner_m.id)
    end

    test "nobody removes themselves; that is leaving", %{workspace: ws, owner: owner} do
      {admin, admin_m} = add_member(ws, :admin)
      assert {:error, :forbidden} = Members.remove(admin, admin_m.id)

      owner_m = Workspaces.get_membership(ws.id, owner.id)
      assert {:error, :forbidden} = Members.remove(workspace_scope_fixture(owner, ws), owner_m.id)
    end

    test "members and viewers cannot remove anyone", %{workspace: ws} do
      {_, target} = add_member(ws, :viewer)

      for role <- [:member, :viewer] do
        {scope, _} = add_member(ws, role)
        assert {:error, :forbidden} = Members.remove(scope, target.id)
      end
    end

    test "rejoining after removal reuses the human identity",
         %{workspace: ws, owner_scope: owner} do
      {bob, bob_m} = add_member(ws, :member)
      {:ok, _} = Members.remove(owner, bob_m.id)

      %{token: token} = invitation_fixture(owner)
      assert {:ok, %{actor: actor}} = Invitations.accept(bob.user, token)
      assert actor.id == bob.actor.id
      assert actor.name == bob.actor.name
    end
  end

  describe "leave/1" do
    test "any member may leave", %{workspace: ws} do
      for role <- [:admin, :member, :viewer] do
        {scope, _} = add_member(ws, role)
        agent = agent!(ws, scope.user, "bot-#{role}")

        assert {:ok, _} = Members.leave(scope)
        refute Workspaces.get_membership(ws.id, scope.user.id)
        assert Repo.reload!(agent).disabled_at
      end
    end

    test "the only owner cannot leave", %{workspace: ws, owner: owner, owner_scope: scope} do
      assert {:error, :last_owner} = Members.leave(scope)
      assert role_of(ws, owner) == :owner
    end

    test "one of two owners may leave", %{workspace: ws, owner_scope: scope} do
      {_bob, _} = add_member(ws, :owner)
      assert {:ok, _} = Members.leave(scope)
    end

    test "an agent cannot leave on its owner's behalf", %{workspace: ws} do
      {scope, _} = add_member(ws, :member)
      agent = agent!(ws, scope.user, "leaver-bot")

      assert {:error, :forbidden} = Members.leave(%{scope | actor: agent})
      assert role_of(ws, scope.user) == :member
    end

    test "a former member gets not_found", %{workspace: ws} do
      {scope, _} = add_member(ws, :member)
      {:ok, _} = Members.leave(scope)
      assert {:error, :not_found} = Members.leave(scope)
    end
  end

  describe "notifications" do
    test "a role change notifies the user and the workspace",
         %{workspace: ws, owner_scope: owner} do
      {alice, alice_m} = add_member(ws, :admin)
      subscribe(ws, alice.user)

      {:ok, _} = Members.change_role(owner, alice_m.id, :member)

      ws_id = ws.id
      assert_receive {:membership_changed, ^ws_id, {:role, :member}}
      assert_receive {:members_changed}
    end

    test "removal and leaving notify :removed", %{workspace: ws, owner_scope: owner} do
      ws_id = ws.id
      {bob, bob_m} = add_member(ws, :member)
      subscribe(ws, bob.user)

      {:ok, _} = Members.remove(owner, bob_m.id)
      assert_receive {:membership_changed, ^ws_id, :removed}
      assert_receive {:members_changed}

      {carol, _} = add_member(ws, :viewer)
      Events.subscribe(Events.topic(:user, carol.user.id))

      {:ok, _} = Members.leave(carol)
      assert_receive {:membership_changed, ^ws_id, :removed}
      assert_receive {:members_changed}
    end

    test "accepting an invitation notifies the workspace", %{workspace: ws, owner_scope: owner} do
      Events.subscribe(Events.topic(:workspace, ws.id))
      %{token: token} = invitation_fixture(owner)

      {:ok, _} = Invitations.accept(user_fixture(), token)
      assert_receive {:members_changed}
    end

    test "failed operations notify nobody", %{workspace: ws, owner: owner, owner_scope: scope} do
      {admin, _} = add_member(ws, :admin)
      subscribe(ws, owner)
      owner_m = Workspaces.get_membership(ws.id, owner.id)

      assert {:error, :last_owner} = Members.change_role(scope, owner_m.id, :admin)
      assert {:error, :last_owner} = Members.leave(scope)
      assert {:error, :forbidden} = Members.remove(admin, owner_m.id)

      refute_receive {:membership_changed, _, _}
      refute_receive {:members_changed}
    end

    test "an unchanged role notifies nobody", %{workspace: ws, owner_scope: owner} do
      {bob, bob_m} = add_member(ws, :member)
      subscribe(ws, bob.user)

      assert {:ok, _} = Members.change_role(owner, bob_m.id, :member)
      refute_receive {:membership_changed, _, _}
    end
  end
end
