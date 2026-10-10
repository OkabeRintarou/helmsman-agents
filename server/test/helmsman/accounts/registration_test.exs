defmodule Helmsman.Accounts.RegistrationTest do
  # Switches the global signup mode.
  use Helmsman.DataCase, async: false

  alias Helmsman.Accounts
  alias Helmsman.Actors.Actor
  alias Helmsman.Invitations.Invitation
  alias Helmsman.Workspaces
  alias Helmsman.Workspaces.Workspace

  import Helmsman.AccountsFixtures
  import Helmsman.WorkspacesFixtures

  defp put_signup_mode(mode) do
    previous = Application.fetch_env!(:helmsman, :signup_mode)
    Application.put_env(:helmsman, :signup_mode, mode)
    on_exit(fn -> Application.put_env(:helmsman, :signup_mode, previous) end)
  end

  describe "invite mode" do
    setup do
      put_signup_mode(:invite)
    end

    test "the first user on an empty instance becomes the instance admin" do
      assert Accounts.registration_open?()
      assert {:ok, user} = Accounts.register_user(valid_user_attributes())
      assert user.instance_admin
      assert Repo.reload!(user).instance_admin
    end

    test "a second user without an invitation is rejected" do
      {:ok, _first} = Accounts.register_user(valid_user_attributes())
      refute Accounts.registration_open?()

      email = unique_user_email()

      assert {:error, :signup_closed} =
               Accounts.register_user(valid_user_attributes(email: email))

      refute Accounts.get_user_by_email(email)
    end
  end

  describe "invite mode with an invitation" do
    setup do
      put_signup_mode(:invite)
      {:ok, first} = Accounts.register_user(valid_user_attributes())
      scope = workspace_scope_fixture(first, Workspaces.get_by_slug("default"))
      %{scope: scope}
    end

    test "a generic invitation lets a visitor register without consuming it", %{scope: scope} do
      %{token: token, invitation: invitation} = invitation_fixture(scope)

      assert {:ok, user} =
               Accounts.register_user(valid_user_attributes(), invitation_token: token)

      refute user.instance_admin
      assert Workspaces.list_for_user(user) == []
      refute Repo.reload!(invitation).accepted_at
    end

    test "an expired invitation is refused", %{scope: scope} do
      %{token: token, invitation: invitation} = invitation_fixture(scope)

      Repo.update_all(from(i in Invitation, where: i.id == ^invitation.id),
        set: [expires_at: DateTime.add(DateTime.utc_now(:second), -1, :second)]
      )

      email = unique_user_email()

      assert {:error, :signup_closed} =
               Accounts.register_user(valid_user_attributes(email: email),
                 invitation_token: token
               )

      refute Accounts.get_user_by_email(email)
    end

    test "a bound invitation only admits its own email", %{scope: scope} do
      bob = unique_user_email()
      %{token: token, invitation: invitation} = invitation_fixture(scope, email: bob)
      eve = unique_user_email()

      assert {:error, :signup_closed} =
               Accounts.register_user(valid_user_attributes(email: eve), invitation_token: token)

      refute Accounts.get_user_by_email(eve)

      # A caller-supplied :email cannot stand in for the registration email.
      assert {:error, :signup_closed} =
               Accounts.register_user(valid_user_attributes(email: eve),
                 invitation_token: token,
                 email: bob
               )

      assert {:ok, _user} =
               Accounts.register_user(valid_user_attributes(email: String.upcase(bob)),
                 invitation_token: token
               )

      refute Repo.reload!(invitation).accepted_at
    end
  end

  describe "open mode" do
    setup do
      put_signup_mode(:open)
    end

    test "a second user registers and is not an instance admin" do
      {:ok, first} = Accounts.register_user(valid_user_attributes())
      assert first.instance_admin
      assert Accounts.registration_open?()

      assert {:ok, second} = Accounts.register_user(valid_user_attributes())
      refute second.instance_admin
    end
  end

  describe "default workspace" do
    test "the first user owns the workspace default" do
      assert {:ok, first} = Accounts.register_user(valid_user_attributes())

      assert {:ok, %{workspace: ws, membership: membership, actor: actor}} =
               Workspaces.fetch_for_user(first, "default")

      assert ws.name == "Default"
      assert membership.role == :owner
      assert actor.kind == :human
      assert Repo.get_by(Actor, workspace_id: ws.id, kind: :system).name == "helmsman"
    end

    test "a second user gets no workspace" do
      put_signup_mode(:open)
      {:ok, _first} = Accounts.register_user(valid_user_attributes())
      {:ok, second} = Accounts.register_user(valid_user_attributes())

      assert Workspaces.list_for_user(second) == []
      assert Repo.aggregate(Workspace, :count) == 1
    end

    test "skip_default_workspace leaves the first user without a workspace" do
      assert {:ok, first} =
               Accounts.register_user(valid_user_attributes(), skip_default_workspace: true)

      assert first.instance_admin
      assert Workspaces.list_for_user(first) == []
    end
  end

  test "skip_signup_gate registers in invite mode" do
    put_signup_mode(:invite)
    {:ok, _first} = Accounts.register_user(valid_user_attributes())

    assert {:ok, user} = Accounts.register_user(valid_user_attributes(), skip_signup_gate: true)
    refute user.instance_admin
  end

  test "instance_admin cannot be set through registration attrs" do
    put_signup_mode(:open)
    {:ok, _first} = Accounts.register_user(valid_user_attributes())

    {:ok, user} = Accounts.register_user(valid_user_attributes(instance_admin: true))
    refute user.instance_admin
  end

  test "signup_mode/0 defaults to :invite" do
    previous = Application.fetch_env!(:helmsman, :signup_mode)
    Application.delete_env(:helmsman, :signup_mode)
    on_exit(fn -> Application.put_env(:helmsman, :signup_mode, previous) end)

    assert Accounts.signup_mode() == :invite
  end
end
