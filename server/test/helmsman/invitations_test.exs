defmodule Helmsman.InvitationsTest do
  use Helmsman.DataCase, async: true

  import Helmsman.AccountsFixtures
  import Helmsman.WorkspacesFixtures
  import Swoosh.TestAssertions

  alias Helmsman.Accounts.User
  alias Helmsman.Actors
  alias Helmsman.Events
  alias Helmsman.Invitations
  alias Helmsman.Invitations.Invitation
  alias Helmsman.Workspaces

  setup do
    owner = user_fixture(%{display_name: "Olivia"})
    workspace = workspace_fixture(owner, %{name: "Acme Corp"})
    %{owner: owner, workspace: workspace, owner_scope: workspace_scope_fixture(owner, workspace)}
  end

  defp scope_with_role(workspace, role) do
    user = user_fixture()
    member_fixture(workspace, user, role)
    workspace_scope_fixture(user, workspace)
  end

  defp expire!(%Invitation{id: id}) do
    Repo.update_all(from(i in Invitation, where: i.id == ^id),
      set: [expires_at: DateTime.add(DateTime.utc_now(:second), -1, :second)]
    )
  end

  defp reload(%Invitation{} = invitation), do: Repo.reload!(invitation)

  # Drops the login emails the user fixtures sent.
  defp flush_emails do
    receive do
      {:email, _} -> flush_emails()
    after
      0 -> :ok
    end
  end

  defp email(name), do: "#{name}-#{System.unique_integer([:positive])}@x.com"

  describe "create/3" do
    test "admin invites bob@x.com as member: link, email, only the hash stored",
         %{workspace: workspace} do
      admin = scope_with_role(workspace, :admin)
      flush_emails()

      assert {:ok, %{invitation: invitation, token: token}} =
               Invitations.create(admin, %{email: "Bob@X.com", role: :member}, &invite_url/1)

      assert invitation.email == "bob@x.com"
      assert invitation.role == :member
      assert invitation.invited_by_id == admin.user.id
      assert byte_size(token) >= 43

      stored = reload(invitation)
      assert stored.token_hash == :crypto.hash(:sha256, token)

      %{rows: rows} = Repo.query!("SELECT invitations::text FROM invitations")
      refute Enum.any?(List.flatten(rows), &String.contains?(&1, token))

      assert_email_sent(fn email ->
        assert email.to == [{"", "bob@x.com"}]
        assert email.text_body =~ "Acme Corp"
        assert email.text_body =~ invite_url(token)
        assert email.text_body =~ admin.user.display_name
        assert email.text_body =~ "member"
      end)
    end

    test "expires after the configured number of days", %{owner_scope: scope} do
      %{invitation: invitation} = invitation_fixture(scope)
      seconds = DateTime.diff(invitation.expires_at, DateTime.utc_now(), :second)
      assert_in_delta seconds, 7 * 24 * 3600, 60
    end

    test "a generic link sends no email", %{owner_scope: scope} do
      flush_emails()

      assert {:ok, %{invitation: %Invitation{email: nil}}} =
               Invitations.create(scope, %{email: "", role: :viewer}, &invite_url/1)

      assert_no_email_sent()
    end

    test "admin cannot invite an owner", %{workspace: workspace} do
      admin = scope_with_role(workspace, :admin)
      flush_emails()

      assert {:error, :forbidden} =
               Invitations.create(admin, %{email: "x@x.com", role: :owner}, &invite_url/1)

      assert Repo.aggregate(Invitation, :count) == 0
      assert_no_email_sent()
    end

    test "admin may invite an admin; owner may invite an owner",
         %{workspace: workspace, owner_scope: owner} do
      admin = scope_with_role(workspace, :admin)
      assert {:ok, _} = Invitations.create(admin, %{role: :admin}, &invite_url/1)
      assert {:ok, _} = Invitations.create(owner, %{role: "owner"}, &invite_url/1)
    end

    test "members and viewers cannot invite", %{workspace: workspace} do
      for role <- [:member, :viewer], invited <- [:viewer, :member] do
        scope = scope_with_role(workspace, role)

        assert {:error, :forbidden} =
                 Invitations.create(scope, %{role: invited}, &invite_url/1)
      end

      assert Repo.aggregate(Invitation, :count) == 0
    end

    test "invalid attributes return a changeset", %{owner_scope: scope} do
      assert {:error, %Ecto.Changeset{} = cs} = Invitations.create(scope, %{}, &invite_url/1)
      assert %{role: ["can't be blank"]} = errors_on(cs)

      assert {:error, %Ecto.Changeset{} = cs} =
               Invitations.create(scope, %{role: :member, email: "nope"}, &invite_url/1)

      assert %{email: [_]} = errors_on(cs)
    end
  end

  describe "list_pending/1 and revoke/2" do
    test "lists only invitations that are not accepted, revoked or expired",
         %{owner_scope: scope} do
      %{invitation: pending} = invitation_fixture(scope, email: "p@x.com")
      %{invitation: expired} = invitation_fixture(scope)
      expire!(expired)
      %{invitation: revoked} = invitation_fixture(scope)
      {:ok, _} = Invitations.revoke(scope, revoked.id)
      %{token: accepted_token} = invitation_fixture(scope)
      {:ok, _} = Invitations.accept(user_fixture(), accepted_token)

      assert {:ok, [listed]} = Invitations.list_pending(scope)
      assert listed.id == pending.id
      assert listed.invited_by.id == scope.user.id
    end

    test "does not list other workspaces' invitations", %{owner: owner, owner_scope: scope} do
      other = workspace_fixture(owner)
      invitation_fixture(workspace_scope_fixture(owner, other))
      assert {:ok, []} = Invitations.list_pending(scope)
    end

    test "members cannot list", %{workspace: workspace} do
      assert {:error, :forbidden} = Invitations.list_pending(scope_with_role(workspace, :member))
    end

    test "a revoked invitation can no longer be accepted", %{workspace: workspace} do
      admin = scope_with_role(workspace, :admin)
      %{invitation: invitation, token: token} = invitation_fixture(admin)

      assert {:ok, revoked} = Invitations.revoke(admin, invitation.id)
      assert revoked.revoked_at
      assert revoked.revoked_by_id == admin.user.id

      assert {:error, :invalid_invitation} = Invitations.accept(user_fixture(), token)
      assert {:error, :invalid_invitation} = Invitations.revoke(admin, invitation.id)
    end

    test "admin cannot revoke an owner invitation", %{workspace: workspace, owner_scope: owner} do
      %{invitation: invitation} = invitation_fixture(owner, role: :owner)
      admin = scope_with_role(workspace, :admin)

      assert {:error, :forbidden} = Invitations.revoke(admin, invitation.id)
      refute reload(invitation).revoked_at
    end

    test "members cannot revoke", %{workspace: workspace, owner_scope: owner} do
      %{invitation: invitation} = invitation_fixture(owner, role: :viewer)

      assert {:error, :forbidden} =
               Invitations.revoke(scope_with_role(workspace, :member), invitation.id)
    end

    test "another workspace's invitation is not found", %{owner: owner, owner_scope: scope} do
      other = workspace_scope_fixture(owner, workspace_fixture(owner))
      %{invitation: invitation} = invitation_fixture(other)
      assert {:error, :not_found} = Invitations.revoke(scope, invitation.id)
    end
  end

  describe "preview/1" do
    test "a valid invitation shows workspace, inviter, role and whether an email is bound",
         %{owner_scope: scope} do
      %{token: token, invitation: invitation} = invitation_fixture(scope, email: "bob@x.com")

      assert {:ok, preview} = Invitations.preview(token)

      assert preview == %{
               workspace_name: "Acme Corp",
               inviter_name: "Olivia",
               role: :member,
               email_bound?: true,
               expires_at: invitation.expires_at
             }

      refute inspect(preview) =~ "bob@x.com"

      %{token: generic} = invitation_fixture(scope)
      assert {:ok, %{email_bound?: false}} = Invitations.preview(generic)
    end

    test "expired, revoked, accepted and unknown tokens look the same", %{owner_scope: scope} do
      %{token: expired, invitation: i1} = invitation_fixture(scope)
      expire!(i1)
      %{token: revoked, invitation: i2} = invitation_fixture(scope)
      {:ok, _} = Invitations.revoke(scope, i2.id)
      %{token: accepted} = invitation_fixture(scope)
      {:ok, _} = Invitations.accept(user_fixture(), accepted)

      results =
        for token <- [expired, revoked, accepted, "no-such-token", nil],
            do: Invitations.preview(token)

      assert Enum.uniq(results) == [{:error, :invalid_invitation}]
    end
  end

  describe "accept/2" do
    test "a generic invitation makes the user a member with a human identity",
         %{workspace: workspace, owner_scope: scope} do
      Events.subscribe(Events.topic(:workspace, workspace.id))
      %{token: token, invitation: invitation} = invitation_fixture(scope, role: :member)
      carol = user_fixture()

      assert {:ok, %{workspace: ws, membership: membership, actor: actor}} =
               Invitations.accept(carol, token)

      assert ws.id == workspace.id
      assert membership.role == :member
      assert actor.kind == :human and actor.user_id == carol.id

      invitation = reload(invitation)
      assert invitation.accepted_at
      assert invitation.accepted_by_id == carol.id

      assert {:ok, _access} = Workspaces.fetch_for_user(carol, workspace.slug)
      assert_receive {:members_changed}

      assert {:error, :invalid_invitation} = Invitations.accept(user_fixture(), token)
    end

    test "an expired invitation is invalid", %{owner_scope: scope} do
      %{token: token, invitation: invitation} = invitation_fixture(scope)
      expire!(invitation)
      assert {:error, :invalid_invitation} = Invitations.accept(user_fixture(), token)
    end

    test "a bound invitation is accepted by its confirmed email, in any case",
         %{owner_scope: scope} do
      bob = user_fixture(%{email: String.capitalize(email("bob"))})
      %{token: token} = invitation_fixture(scope, email: String.upcase(bob.email))
      assert {:ok, _} = Invitations.accept(bob, token)
    end

    test "a bound invitation refuses another email and stays usable", %{owner_scope: scope} do
      Events.subscribe(Events.topic(:workspace, scope.workspace.id))
      %{token: token, invitation: invitation} = invitation_fixture(scope, email: email("bob"))
      eve = user_fixture(%{email: email("eve")})

      assert {:error, :email_mismatch} = Invitations.accept(eve, token)
      refute reload(invitation).accepted_at
      refute Workspaces.get_membership(scope.workspace.id, eve.id)
      refute_receive {:members_changed}
    end

    test "the current email in the database decides, not the struct passed in",
         %{owner_scope: scope} do
      bob = user_fixture(%{email: email("bob")})
      %{token: token, invitation: invitation} = invitation_fixture(scope, email: bob.email)

      # The page was opened with the old email; it changed since.
      Repo.update_all(from(u in User, where: u.id == ^bob.id), set: [email: email("eve")])

      assert {:error, :email_mismatch} = Invitations.accept(bob, token)
      refute reload(invitation).accepted_at
    end

    test "a bound invitation needs a confirmed email", %{owner_scope: scope} do
      bob = unconfirmed_user_fixture(%{email: email("bob")})
      %{token: token, invitation: invitation} = invitation_fixture(scope, email: bob.email)

      assert {:error, :email_unconfirmed} = Invitations.accept(bob, token)
      refute reload(invitation).accepted_at

      # A struct claiming confirmation does not help either.
      assert {:error, :email_unconfirmed} =
               Invitations.accept(%{bob | confirmed_at: DateTime.utc_now(:second)}, token)
    end

    test "an existing member keeps their role and the invitation stays usable",
         %{workspace: workspace, owner_scope: scope} do
      admin = scope_with_role(workspace, :admin)
      %{token: token, invitation: invitation} = invitation_fixture(scope, role: :viewer)

      assert {:error, :already_member} = Invitations.accept(admin.user, token)
      assert Workspaces.get_membership(workspace.id, admin.user.id).role == :admin
      refute reload(invitation).accepted_at
    end

    test "rejoining reuses the human identity", %{workspace: workspace, owner_scope: scope} do
      bob = user_fixture()
      %{token: first} = invitation_fixture(scope)
      {:ok, %{actor: actor, membership: membership}} = Invitations.accept(bob, first)
      {:ok, _} = Actors.rename(workspace_scope_fixture(bob, workspace), actor, "bobby")

      {:ok, _} = Helmsman.Members.remove(scope, membership.id)

      %{token: second} = invitation_fixture(scope)
      assert {:ok, %{actor: again}} = Invitations.accept(bob, second)
      assert again.id == actor.id
      assert again.name == "bobby"
    end
  end

  describe "check_signup/2" do
    test "a generic invitation allows any email", %{owner_scope: scope} do
      %{token: token} = invitation_fixture(scope)
      assert :ok = Invitations.check_signup(token, "anyone@x.com")
    end

    test "a bound invitation allows only its email", %{owner_scope: scope} do
      %{token: token} = invitation_fixture(scope, email: "bob@x.com")
      assert :ok = Invitations.check_signup(token, " BOB@x.com ")
      assert {:error, :invalid_invitation} = Invitations.check_signup(token, "eve@x.com")
    end

    test "invalid invitations are refused", %{owner_scope: scope} do
      %{token: token, invitation: invitation} = invitation_fixture(scope)
      expire!(invitation)
      assert {:error, :invalid_invitation} = Invitations.check_signup(token, "a@x.com")
      assert {:error, :invalid_invitation} = Invitations.check_signup("nope", "a@x.com")
    end
  end
end
