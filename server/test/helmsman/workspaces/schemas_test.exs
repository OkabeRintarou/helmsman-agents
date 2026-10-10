defmodule Helmsman.Workspaces.SchemasTest do
  use Helmsman.DataCase, async: true

  import Helmsman.AccountsFixtures

  alias Helmsman.Actors.Actor
  alias Helmsman.Workspaces.{Membership, Workspace}

  describe "Workspace.changeset/2" do
    test "accepts valid input, downcasing the slug and trimming the name" do
      changeset = Workspace.changeset(%Workspace{}, %{slug: "Acme-1", name: "  Acme Inc. "})
      assert changeset.valid?
      assert get_change(changeset, :slug) == "acme-1"
      assert get_change(changeset, :name) == "Acme Inc."
    end

    test "rejects invalid slugs" do
      for slug <- ["-acme", "a", "acme_inc", "ac me", String.duplicate("a", 40), ""] do
        changeset = Workspace.changeset(%Workspace{}, %{slug: slug, name: "Acme"})
        assert %{slug: [_]} = errors_on(changeset), "expected #{inspect(slug)} to be rejected"
      end

      assert Workspace.changeset(%Workspace{}, %{slug: String.duplicate("a", 39), name: "A"}).valid?
    end

    test "rejects blank and too long names" do
      for name <- ["   ", String.duplicate("n", 81)] do
        changeset = Workspace.changeset(%Workspace{}, %{slug: "acme", name: name})
        assert %{name: [_]} = errors_on(changeset)
      end
    end

    test "maps the unique slug index to a changeset error" do
      {:ok, _} =
        Repo.insert(Workspace.changeset(%Workspace{}, %{slug: "acme", name: "Acme"}))

      assert {:error, changeset} =
               Repo.insert(Workspace.changeset(%Workspace{}, %{slug: "ACME", name: "Other"}))

      assert %{slug: ["has already been taken"]} = errors_on(changeset)
    end
  end

  describe "Membership.changeset/2" do
    setup do
      user = user_fixture()
      {:ok, ws} = Repo.insert(Workspace.changeset(%Workspace{}, %{slug: "acme", name: "Acme"}))
      %{user: user, ws: ws}
    end

    test "accepts every role", %{user: user, ws: ws} do
      for role <- Membership.roles() do
        changeset =
          Membership.changeset(%Membership{workspace_id: ws.id, user_id: user.id}, %{role: role})

        assert changeset.valid?
      end
    end

    test "rejects an unknown or missing role", %{user: user, ws: ws} do
      base = %Membership{workspace_id: ws.id, user_id: user.id}
      assert %{role: ["is invalid"]} = errors_on(Membership.changeset(base, %{role: "guest"}))
      assert %{role: ["can't be blank"]} = errors_on(Membership.changeset(base, %{}))
    end

    test "maps the unique membership index", %{user: user, ws: ws} do
      base = %Membership{workspace_id: ws.id, user_id: user.id}
      {:ok, _} = Repo.insert(Membership.changeset(base, %{role: :owner}))
      assert {:error, changeset} = Repo.insert(Membership.changeset(base, %{role: :viewer}))
      assert %{workspace_id: ["is already a member"]} = errors_on(changeset)
    end
  end

  describe "Actor changesets" do
    setup do
      user = user_fixture()
      {:ok, ws} = Repo.insert(Workspace.changeset(%Workspace{}, %{slug: "acme", name: "Acme"}))
      %{user: user, ws: ws}
    end

    test "accepts valid names", %{ws: ws} do
      for name <- ["alice", "a", "alice.w", "ops-bob", "team/bot_1", String.duplicate("a", 64)] do
        changeset =
          Actor.create_changeset(%Actor{workspace_id: ws.id, kind: :squad}, %{name: name})

        assert changeset.valid?, "expected #{inspect(name)} to be valid"
      end
    end

    test "rejects invalid names", %{ws: ws} do
      for name <- ["Alice Smith", "_bot", "Alice", String.duplicate("a", 65), ""] do
        changeset =
          Actor.create_changeset(%Actor{workspace_id: ws.id, kind: :squad}, %{name: name})

        assert %{name: [_]} = errors_on(changeset), "expected #{inspect(name)} to be rejected"
      end
    end

    test "helmsman is taken for everyone but the system identity", %{ws: ws} do
      for name <- ["helmsman", "HELMSMAN"] do
        changeset =
          Actor.rename_changeset(%Actor{workspace_id: ws.id, kind: :human}, %{name: name})

        assert %{name: ["has already been taken"]} = errors_on(changeset)
      end

      assert Actor.create_changeset(%Actor{workspace_id: ws.id, kind: :system}, %{
               name: "helmsman"
             }).valid?
    end

    test "validates the links of each kind", %{ws: ws, user: user} do
      agent = %Actor{workspace_id: ws.id, kind: :agent}
      assert %{owner_id: [_]} = errors_on(Actor.create_changeset(agent, %{name: "bot"}))

      assert Actor.create_changeset(%{agent | owner_id: user.id}, %{name: "bot"}).valid?

      human = %Actor{workspace_id: ws.id, kind: :human, owner_id: user.id}
      assert %{owner_id: [_]} = errors_on(Actor.create_changeset(human, %{name: "alice"}))

      system = %Actor{workspace_id: ws.id, kind: :system, user_id: user.id}
      assert %{user_id: [_]} = errors_on(Actor.create_changeset(system, %{name: "helmsman"}))
    end

    test "maps the unique indexes", %{ws: ws, user: user} do
      human = %Actor{workspace_id: ws.id, kind: :human, user_id: user.id}
      {:ok, _} = Repo.insert(Actor.create_changeset(human, %{name: "alice"}))

      assert {:error, changeset} =
               Repo.insert(
                 Actor.create_changeset(%Actor{workspace_id: ws.id, kind: :squad}, %{
                   name: "alice"
                 })
               )

      assert %{name: ["has already been taken"]} = errors_on(changeset)

      assert {:error, changeset} = Repo.insert(Actor.create_changeset(human, %{name: "alice2"}))
      assert %{user_id: [_]} = errors_on(changeset)

      system = %Actor{workspace_id: ws.id, kind: :system}
      {:ok, _} = Repo.insert(Actor.create_changeset(system, %{name: "helmsman"}))

      assert {:error, changeset} =
               Repo.insert(Actor.create_changeset(system, %{name: "helmsman-2"}))

      assert %{kind: [_]} = errors_on(changeset)
    end
  end
end
