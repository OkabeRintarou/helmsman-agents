defmodule Helmsman.ActorsTest do
  use Helmsman.DataCase, async: true

  import Helmsman.AccountsFixtures
  import Helmsman.WorkspacesFixtures

  alias Helmsman.Actors
  alias Helmsman.Actors.Actor
  alias Helmsman.Tx

  describe "derive_human_name/1" do
    test "follows the naming steps" do
      assert Actors.derive_human_name("Alice.W@example.com") == "alice.w"
      assert Actors.derive_human_name("+ops+bob@example.com") == "ops-bob"
      assert Actors.derive_human_name("a_b-c@x") == "a_b-c"
      assert Actors.derive_human_name("Zoë Smith@x") == "zo--smith"
    end

    test "truncates long local parts to 60 characters" do
      name = Actors.derive_human_name(String.duplicate("a", 70) <> "@example.com")
      assert name == String.duplicate("a", 60)
    end

    test "an empty result becomes user" do
      assert Actors.derive_human_name("+++@example.com") == "user"
      assert Actors.derive_human_name("@example.com") == "user"
      assert Actors.derive_human_name("-._@example.com") == "user"
    end
  end

  describe "ensure_human/2" do
    setup do
      owner = user_fixture(%{email: "owner@example.com"})
      %{owner: owner, workspace: workspace_fixture(owner)}
    end

    defp ensure(workspace, user), do: Tx.run(fn -> Actors.ensure_human(workspace, user) end)

    test "the creator gets a human identity named after the email",
         %{owner: owner, workspace: ws} do
      assert %Actor{kind: :human, name: "owner"} = Actors.get_human(ws.id, owner.id)
    end

    test "a conflicting name gets -2, -3, ...", %{workspace: ws} do
      a = user_fixture(%{email: "alice@example.com"})
      b = user_fixture(%{email: "alice@other.org"})
      c = user_fixture(%{email: "ALICE@third.net"})

      assert {:ok, %Actor{name: "alice"}} = ensure(ws, a)
      assert {:ok, %Actor{name: "alice-2"}} = ensure(ws, b)
      assert {:ok, %Actor{name: "alice-3"}} = ensure(ws, c)
    end

    test "the reserved name helmsman is skipped", %{workspace: ws} do
      user = user_fixture(%{email: "Helmsman@example.com"})
      assert {:ok, %Actor{name: "helmsman-2"}} = ensure(ws, user)
    end

    test "a 60-character base keeps its suffix within 64 characters", %{workspace: ws} do
      local = String.duplicate("b", 70)
      first = user_fixture(%{email: "#{local}@example.com"})
      second = user_fixture(%{email: "#{local}@other.org"})

      assert {:ok, %Actor{name: base}} = ensure(ws, first)
      assert base == String.duplicate("b", 60)
      assert {:ok, %Actor{name: suffixed}} = ensure(ws, second)
      assert suffixed == base <> "-2"
    end

    test "names with LIKE wildcards do not match other names", %{workspace: ws} do
      _ = ensure(ws, user_fixture(%{email: "a_b-x@example.com"}))
      user = user_fixture(%{email: "a_b@example.com"})
      assert {:ok, %Actor{name: "a_b"}} = ensure(ws, user)
    end

    test "calling it again returns the same identity", %{owner: owner, workspace: ws} do
      existing = Actors.get_human(ws.id, owner.id)
      assert {:ok, ^existing} = ensure(ws, owner)
      query = from(a in Actor, where: a.workspace_id == ^ws.id and a.kind == :human)
      assert Repo.aggregate(query, :count) == 1
    end
  end

  describe "ensure_system/1" do
    test "creates helmsman once per workspace" do
      owner = user_fixture()
      ws = workspace_fixture(owner)

      assert {:ok, %Actor{kind: :system, name: "helmsman"} = system} =
               Tx.run(fn -> Actors.ensure_system(ws) end)

      assert {:ok, ^system} = Tx.run(fn -> Actors.ensure_system(ws) end)
    end
  end

  describe "rename_own/2 and rename/3" do
    setup do
      owner = user_fixture(%{email: "alice.w@example.com"})
      ws = workspace_fixture(owner)
      bob = user_fixture(%{email: "bob@example.com"})
      member_fixture(ws, bob, :viewer)

      %{
        ws: ws,
        owner_scope: workspace_scope_fixture(owner, ws),
        bob_scope: workspace_scope_fixture(bob, ws)
      }
    end

    test "renames the caller's own identity", %{owner_scope: scope} do
      assert scope.actor.name == "alice.w"
      assert {:ok, %Actor{name: "alice"}} = Actors.rename_own(scope, "alice")
      assert Repo.reload!(scope.actor).name == "alice"
    end

    test "a viewer may rename their own identity", %{bob_scope: scope} do
      assert scope.role == :viewer
      assert {:ok, %Actor{name: "robert"}} = Actors.rename_own(scope, "robert")
    end

    test "a taken name fails", %{owner_scope: scope} do
      assert {:error, changeset} = Actors.rename_own(scope, "bob")
      assert %{name: ["has already been taken"]} = errors_on(changeset)
    end

    test "the reserved name fails as taken", %{owner_scope: scope} do
      for name <- ["helmsman", "HELMSMAN"] do
        assert {:error, changeset} = Actors.rename_own(scope, name)
        assert %{name: ["has already been taken"]} = errors_on(changeset)
      end
    end

    test "an invalid name explains the rule", %{owner_scope: scope} do
      for name <- ["Alice Smith", "_bot", String.duplicate("a", 65)] do
        assert {:error, changeset} = Actors.rename_own(scope, name)
        assert %{name: [message]} = errors_on(changeset)
        assert message =~ "must be 1-64 characters"
      end

      assert Repo.reload!(scope.actor).name == "alice.w"
    end

    test "an admin cannot rename someone else's identity",
         %{owner_scope: owner_scope, bob_scope: bob_scope} do
      assert {:error, :forbidden} = Actors.rename(owner_scope, bob_scope.actor, "bobby")
      assert Repo.reload!(bob_scope.actor).name == "bob"
    end

    test "nobody can rename the system identity", %{ws: ws, owner_scope: scope} do
      system = Repo.one!(from(a in Actor, where: a.workspace_id == ^ws.id and a.kind == :system))
      assert {:error, :forbidden} = Actors.rename(scope, system, "robot")
      assert Repo.reload!(system).name == "helmsman"
    end
  end
end
