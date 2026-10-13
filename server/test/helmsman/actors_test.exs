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

  describe "list_assignable/1" do
    # `add-squads` decision 4: squads that are not disabled come last.
    test "humans, agents then squads by name; no system or disabled identities" do
      owner = user_fixture(%{email: "zed@example.com"})
      ws = workspace_fixture(owner)
      member = user_fixture(%{email: "amy@example.com"})
      member_fixture(ws, member, :viewer)
      {:ok, _system} = Actors.ensure_system(ws)

      insert = fn attrs -> Repo.insert!(struct!(%Actor{workspace_id: ws.id}, attrs)) end
      insert.(kind: :agent, name: "keel/dev", owner_id: member.id)
      insert.(kind: :agent, name: "claude", owner_id: owner.id)

      insert.(
        kind: :agent,
        name: "old",
        owner_id: owner.id,
        disabled_at: DateTime.utc_now(:second)
      )

      insert.(kind: :squad, name: "team")
      insert.(kind: :squad, name: "gone", disabled_at: DateTime.utc_now(:second))

      other = user_fixture()
      other_ws = workspace_fixture(other)

      Repo.insert!(%Actor{
        workspace_id: other_ws.id,
        kind: :agent,
        name: "far",
        owner_id: other.id
      })

      scope = workspace_scope_fixture(member, ws)
      assert {:ok, actors} = Actors.list_assignable(scope)

      assert Enum.map(actors, &{&1.kind, &1.name}) == [
               human: "amy",
               human: "zed",
               agent: "claude",
               agent: "keel/dev",
               squad: "team"
             ]

      assert Enum.find(actors, &(&1.name == "keel/dev")).owner.id == member.id
      assert Enum.find(actors, &(&1.name == "amy")).owner == nil
    end

    test "scopes without a role are refused" do
      owner = user_fixture()
      scope = workspace_scope_fixture(owner, workspace_fixture(owner))
      assert Actors.list_assignable(%{scope | role: nil}) == {:error, :forbidden}
    end
  end

  describe "list_own_agents/1" do
    setup do
      owner = user_fixture()
      ws = workspace_fixture(owner)
      viewer = user_fixture()
      member_fixture(ws, viewer, :viewer)
      insert = fn attrs -> Repo.insert!(struct!(%Actor{workspace_id: ws.id}, attrs)) end
      %{owner: owner, ws: ws, viewer: viewer, insert: insert}
    end

    test "the user's enabled agents in this workspace, by name",
         %{owner: owner, ws: ws, viewer: viewer, insert: insert} do
      insert.(kind: :agent, name: "zeta", owner_id: viewer.id)
      insert.(kind: :agent, name: "alpha", owner_id: viewer.id)

      insert.(
        kind: :agent,
        name: "old",
        owner_id: viewer.id,
        disabled_at: DateTime.utc_now(:second)
      )

      insert.(kind: :agent, name: "boss", owner_id: owner.id)
      insert.(kind: :squad, name: "team")

      other_ws = workspace_fixture(user_fixture())
      member_fixture(other_ws, viewer, :member)

      Repo.insert!(%Actor{
        workspace_id: other_ws.id,
        kind: :agent,
        name: "far",
        owner_id: viewer.id
      })

      names = fn scope -> scope |> Actors.list_own_agents() |> Enum.map(& &1.name) end
      assert names.(workspace_scope_fixture(viewer, ws)) == ["alpha", "zeta"]
      assert names.(workspace_scope_fixture(owner, ws)) == ["boss"]
      assert names.(workspace_scope_fixture(viewer, other_ws)) == ["far"]
    end

    test "no agents", %{ws: ws, viewer: viewer} do
      assert Actors.list_own_agents(workspace_scope_fixture(viewer, ws)) == []
    end

    test "scopes without a role or acting as an agent get nothing",
         %{ws: ws, viewer: viewer, insert: insert} do
      agent = insert.(kind: :agent, name: "alpha", owner_id: viewer.id)
      scope = workspace_scope_fixture(viewer, ws)

      assert Actors.list_own_agents(%{scope | role: nil}) == []
      assert Actors.list_own_agents(%{scope | actor: agent}) == []
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
