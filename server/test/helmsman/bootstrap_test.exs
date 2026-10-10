defmodule Helmsman.BootstrapTest do
  # Switches the global signup mode.
  use Helmsman.DataCase, async: false

  import Helmsman.AccountsFixtures

  alias Helmsman.Accounts
  alias Helmsman.Accounts.User
  alias Helmsman.Actors.Actor
  alias Helmsman.Bootstrap
  alias Helmsman.Workspaces
  alias Helmsman.Workspaces.{Membership, Workspace}

  setup do
    previous = Application.fetch_env!(:helmsman, :signup_mode)
    Application.put_env(:helmsman, :signup_mode, :invite)
    on_exit(fn -> Application.put_env(:helmsman, :signup_mode, previous) end)
  end

  defp counts do
    for schema <- [User, Workspace, Membership, Actor], into: %{} do
      {schema, Repo.aggregate(schema, :count)}
    end
  end

  test "on an empty instance creates a confirmed admin and the workspace, without default" do
    assert {:ok, %{user: user, workspace: ws, login_token: token, created: created}} =
             Bootstrap.run(email: "you@x.com", workspace: "Acme")

    assert created == [:user, :workspace]
    assert user.instance_admin
    assert user.confirmed_at
    assert ws.slug == "acme"
    assert ws.name == "Acme"

    assert {:ok, %{membership: %Membership{role: :owner}}} =
             Workspaces.fetch_for_user(user, "acme")

    refute Workspaces.get_by_slug("default")
    assert %User{id: id} = Accounts.get_user_by_magic_link_token(token)
    assert id == user.id
  end

  test "uses the given name" do
    assert {:ok, %{workspace: %Workspace{name: "Acme Inc."}}} =
             Bootstrap.run(email: "you@x.com", workspace: "acme", name: "Acme Inc.")
  end

  test "creates a user despite invite-only signup on a non-empty instance" do
    _existing = user_fixture()

    assert {:ok, %{user: user, created: [:user, :workspace]}} =
             Bootstrap.run(email: "ops@x.com", workspace: "ops")

    refute user.instance_admin
    assert user.confirmed_at
  end

  test "running it again changes nothing and returns a new login token" do
    {:ok, first} = Bootstrap.run(email: "you@x.com", workspace: "acme")
    before = counts()

    assert {:ok, %{user: user, workspace: ws, login_token: token, created: []}} =
             Bootstrap.run(email: "you@x.com", workspace: "acme")

    assert counts() == before
    assert user.id == first.user.id
    assert ws.id == first.workspace.id
    assert token != first.login_token
    assert Accounts.get_user_by_magic_link_token(token).id == user.id
  end

  test "an existing user becomes the owner of a new workspace" do
    user = user_fixture()

    assert {:ok, %{created: [:workspace]}} = Bootstrap.run(email: user.email, workspace: "new")
    assert {:ok, %{membership: %{role: :owner}}} = Workspaces.fetch_for_user(user, "new")
  end

  test "fails without changes when the workspace belongs to someone else" do
    {:ok, _} = Bootstrap.run(email: "you@x.com", workspace: "acme")
    {:ok, %{user: other}} = Bootstrap.run(email: "other@x.com", workspace: "other")
    before = counts()

    assert {:error, :not_a_member} = Bootstrap.run(email: "other@x.com", workspace: "acme")
    assert counts() == before
    refute Workspaces.get_membership(Workspaces.get_by_slug("acme").id, other.id)
  end

  test "a new user is rolled back when the workspace already belongs to someone else" do
    {:ok, _} = Bootstrap.run(email: "you@x.com", workspace: "acme")
    before = counts()

    assert {:error, :not_a_member} = Bootstrap.run(email: "new@x.com", workspace: "acme")
    assert counts() == before
    refute Accounts.get_user_by_email("new@x.com")
  end

  test "invalid input returns a changeset and writes nothing" do
    before = counts()
    assert {:error, %Ecto.Changeset{}} = Bootstrap.run(email: "you@x.com", workspace: "-bad")
    assert {:error, %Ecto.Changeset{}} = Bootstrap.run(email: "not-an-email", workspace: "ok")
    assert counts() == before
  end
end
