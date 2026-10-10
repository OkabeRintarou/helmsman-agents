defmodule Helmsman.SchemaConstraintsTest do
  # Inserts raw rows, bypassing changesets, to prove the database itself
  # rejects invalid data. Some tests drop a constraint inside the sandbox
  # transaction (rolled back afterwards); the DDL locks the table, so the
  # module does not run concurrently with others.
  use Helmsman.DataCase, async: false

  import Helmsman.AccountsFixtures

  setup do
    user = user_fixture()
    other = user_fixture()
    workspace_id = insert!("workspaces", %{slug: "acme", name: "Acme"})
    %{user: user, other: other, workspace_id: workspace_id}
  end

  defp insert!(table, row) do
    now = DateTime.utc_now(:second)

    {1, [%{id: id}]} =
      Repo.insert_all(table, [Map.merge(%{inserted_at: now, updated_at: now}, row)],
        returning: [:id]
      )

    id
  end

  # Runs the insert in a savepoint so the sandbox transaction stays usable,
  # and returns the name of the violated constraint.
  defp rejected(table, row) do
    error =
      assert_raise Postgrex.Error, fn ->
        Repo.transaction(fn -> insert!(table, row) end)
      end

    error.postgres.constraint
  end

  defp actor(workspace_id, attrs),
    do: Map.merge(%{workspace_id: workspace_id, kind: "human", name: "someone"}, attrs)

  describe "workspaces" do
    test "rejects invalid slugs" do
      for slug <- ["-acme", "a", "acme_inc", "Acme2", String.duplicate("a", 40)] do
        assert rejected("workspaces", %{slug: slug, name: "X"}) == "workspaces_slug_format"
      end
    end

    test "rejects names of 81 characters and empty names" do
      for name <- [String.duplicate("n", 81), ""] do
        assert rejected("workspaces", %{slug: "other", name: name}) == "workspaces_name_length"
      end

      assert insert!("workspaces", %{slug: "other", name: String.duplicate("n", 80)})
    end

    test "slugs are unique regardless of case" do
      assert rejected("workspaces", %{slug: "ACME", name: "X"}) in [
               "workspaces_slug_index",
               "workspaces_slug_format"
             ]

      # Upper case already fails the format check; drop it to reach the index.
      Repo.query!("ALTER TABLE workspaces DROP CONSTRAINT workspaces_slug_format")
      assert rejected("workspaces", %{slug: "ACME", name: "X"}) == "workspaces_slug_index"
    end
  end

  describe "memberships" do
    test "rejects an invalid role", %{user: user, workspace_id: ws} do
      assert rejected("memberships", %{workspace_id: ws, user_id: user.id, role: "guest"}) ==
               "memberships_role_check"
    end

    test "one membership per user and workspace", %{user: user, workspace_id: ws} do
      insert!("memberships", %{workspace_id: ws, user_id: user.id, role: "owner"})

      assert rejected("memberships", %{workspace_id: ws, user_id: user.id, role: "viewer"}) ==
               "memberships_workspace_id_user_id_index"
    end
  end

  describe "actors" do
    test "an agent needs an owner", %{workspace_id: ws} do
      assert rejected("actors", actor(ws, %{kind: "agent", name: "bot"})) ==
               "actors_agent_owner_check"
    end

    test "an agent cannot have a login user", %{user: user, other: other, workspace_id: ws} do
      row = actor(ws, %{kind: "agent", name: "bot", owner_id: user.id, user_id: other.id})
      assert rejected("actors", row) == "actors_user_only_human_check"
    end

    test "only agents have an owner", %{user: user, workspace_id: ws} do
      assert rejected("actors", actor(ws, %{kind: "human", owner_id: user.id})) ==
               "actors_agent_owner_check"
    end

    test "a system identity cannot have a login user", %{user: user, workspace_id: ws} do
      row = actor(ws, %{kind: "system", name: "helmsman", user_id: user.id})
      assert rejected("actors", row) == "actors_user_only_human_check"
    end

    test "rejects an invalid kind", %{workspace_id: ws} do
      assert rejected("actors", actor(ws, %{kind: "robot"})) == "actors_kind_check"
    end

    test "rejects invalid names", %{workspace_id: ws} do
      for name <- ["Alice Smith", "_bot", "Alice", String.duplicate("a", 65)] do
        assert rejected("actors", actor(ws, %{name: name})) == "actors_name_format"
      end

      assert insert!("actors", actor(ws, %{name: String.duplicate("a", 64)}))
    end

    test "only the system identity may be called helmsman", %{workspace_id: ws} do
      for kind <- ["human", "squad"] do
        assert rejected("actors", actor(ws, %{kind: kind, name: "helmsman"})) ==
                 "actors_reserved_name_check"
      end

      assert insert!("actors", actor(ws, %{kind: "system", name: "helmsman"}))
    end

    test "one human identity per user and workspace", %{user: user, workspace_id: ws} do
      insert!("actors", actor(ws, %{name: "alice", user_id: user.id}))

      assert rejected("actors", actor(ws, %{name: "alice2", user_id: user.id})) ==
               "actors_one_human_per_user_index"
    end

    test "one system identity per workspace", %{workspace_id: ws} do
      insert!("actors", actor(ws, %{kind: "system", name: "helmsman"}))

      assert rejected("actors", actor(ws, %{kind: "system", name: "helmsman-2"})) ==
               "actors_one_system_per_workspace_index"
    end

    test "names are unique per workspace regardless of case", %{workspace_id: ws} do
      insert!("actors", actor(ws, %{name: "alice"}))
      # Upper case already fails the format check; drop it to reach the index.
      Repo.query!("ALTER TABLE actors DROP CONSTRAINT actors_name_format")

      assert rejected("actors", actor(ws, %{name: "ALICE"})) == "actors_workspace_id_name_index"

      other_ws = insert!("workspaces", %{slug: "beta", name: "Beta"})
      assert insert!("actors", actor(other_ws, %{name: "alice"}))
    end
  end
end
