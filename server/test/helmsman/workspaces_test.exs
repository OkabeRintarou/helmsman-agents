defmodule Helmsman.WorkspacesTest do
  use Helmsman.DataCase, async: true

  import Helmsman.AccountsFixtures
  import Helmsman.WorkspacesFixtures

  alias Helmsman.Actors.Actor
  alias Helmsman.Events
  alias Helmsman.Tx
  alias Helmsman.Workspaces
  alias Helmsman.Workspaces.{Membership, Workspace}

  defp counts do
    for schema <- [Workspace, Membership, Actor],
        into: %{},
        do: {schema, Repo.aggregate(schema, :count)}
  end

  describe "create/2" do
    setup do
      %{alice: user_fixture(%{email: "alice@example.com"})}
    end

    test "creates the workspace, the owner membership and both identities", %{alice: alice} do
      assert {:ok, %Workspace{slug: "acme", name: "Acme Inc."} = ws} =
               Workspaces.create(alice, %{slug: "Acme", name: " Acme Inc. "})

      assert %Membership{role: :owner} = Workspaces.get_membership(ws.id, alice.id)

      actors =
        Repo.all(
          from(a in Actor,
            where: a.workspace_id == ^ws.id,
            order_by: a.kind,
            select: {a.kind, a.name, a.user_id}
          )
        )

      assert actors == [{:human, "alice", alice.id}, {:system, "helmsman", nil}]
    end

    test "rejects invalid slugs without writing anything", %{alice: alice} do
      before = counts()

      for slug <- ["-acme", "a", "acme_inc", String.duplicate("a", 40)] do
        assert {:error, changeset} = Workspaces.create(alice, %{slug: slug, name: "Acme"})
        assert %{slug: [message]} = errors_on(changeset)
        assert message =~ "2-39 characters"
      end

      assert counts() == before
    end

    test "rejects a slug taken in another case without writing anything", %{alice: alice} do
      {:ok, _} = Workspaces.create(alice, %{slug: "acme", name: "Acme"})
      before = counts()

      other = user_fixture()
      assert {:error, changeset} = Workspaces.create(other, %{slug: "ACME", name: "Other"})
      assert %{slug: ["has already been taken"]} = errors_on(changeset)
      assert counts() == before
    end

    test "a failure after the workspace insert rolls everything back", %{alice: alice} do
      before = counts()

      # The second membership insert of the same user fails inside the
      # transaction, after the workspace and the first rows were written.
      assert {:error, :boom} =
               Tx.run(fn ->
                 {:ok, _ws} =
                   Workspaces.create_in_transaction(alice, %{slug: "acme", name: "Acme"})

                 {:error, :boom}
               end)

      assert counts() == before
    end
  end

  describe "fetch_for_user/2 and list_for_user/1" do
    setup do
      alice = user_fixture()
      bob = user_fixture()
      acme = workspace_fixture(alice, %{slug: "acme", name: "Acme"})
      beta = workspace_fixture(bob, %{slug: "beta", name: "beta"})
      member_fixture(beta, alice, :viewer)
      _gamma = workspace_fixture(bob, %{slug: "gamma", name: "Gamma"})
      %{alice: alice, bob: bob, acme: acme, beta: beta}
    end

    test "a member gets the workspace, the membership and the human identity",
         %{alice: alice, acme: acme} do
      assert {:ok, %{workspace: ws, membership: m, actor: actor}} =
               Workspaces.fetch_for_user(alice, "ACME")

      assert ws.id == acme.id
      assert m.role == :owner
      assert %Actor{kind: :human, user_id: user_id} = actor
      assert user_id == alice.id
    end

    test "non-members and unknown slugs get the same :not_found", %{bob: bob} do
      assert Workspaces.fetch_for_user(bob, "acme") == {:error, :not_found}
      assert Workspaces.fetch_for_user(bob, "no-such-ws") == {:error, :not_found}
    end

    test "lists only the user's workspaces with roles, by name", %{alice: alice} do
      list =
        for %{workspace: ws, role: role} <- Workspaces.list_for_user(alice),
            ws.slug != "default",
            do: {ws.slug, role}

      assert list == [{"acme", :owner}, {"beta", :viewer}]
    end
  end

  describe "update/2" do
    setup do
      owner = user_fixture()
      ws = workspace_fixture(owner, %{slug: "acme", name: "Acme"})

      scopes =
        for role <- [:admin, :member, :viewer],
            into: %{owner: workspace_scope_fixture(owner, ws)} do
          user = user_fixture()
          member_fixture(ws, user, role)
          {role, workspace_scope_fixture(user, ws)}
        end

      Events.subscribe(Events.topic(:workspace, ws.id))
      %{ws: ws, scopes: scopes}
    end

    test "the owner changes the slug; the old slug stops resolving",
         %{ws: ws, scopes: scopes} do
      assert {:ok, %Workspace{slug: "acme-cn"}} =
               Workspaces.update(scopes.owner, %{slug: "acme-cn"})

      id = ws.id
      assert_receive {:workspace_updated, %{id: ^id, name: "Acme", slug: "acme-cn"}}

      user = scopes.owner.user
      assert {:ok, _} = Workspaces.fetch_for_user(user, "acme-cn")
      assert {:error, :not_found} = Workspaces.fetch_for_user(user, "acme")
    end

    test "owner and admin change the name", %{ws: ws, scopes: scopes} do
      id = ws.id

      assert {:ok, %Workspace{name: "Acme 2"}} =
               Workspaces.update(scopes.admin, %{name: "Acme 2"})

      assert_receive {:workspace_updated, %{id: ^id, name: "Acme 2", slug: "acme"}}

      assert {:ok, %Workspace{name: "Acme 3"}} =
               Workspaces.update(scopes.owner, %{name: "Acme 3"})

      assert_receive {:workspace_updated, %{name: "Acme 3"}}
    end

    test "an admin cannot change the slug", %{ws: ws, scopes: scopes} do
      assert {:error, :forbidden} = Workspaces.update(scopes.admin, %{slug: "acme-cn"})

      assert {:error, :forbidden} =
               Workspaces.update(scopes.admin, %{name: "New", slug: "acme-cn"})

      assert %Workspace{slug: "acme", name: "Acme"} = Repo.reload!(ws)
      refute_receive {:workspace_updated, _}
    end

    test "member and viewer cannot change the name", %{ws: ws, scopes: scopes} do
      for role <- [:member, :viewer] do
        assert {:error, :forbidden} = Workspaces.update(scopes[role], %{name: "New"})
      end

      assert Repo.reload!(ws).name == "Acme"
      refute_receive {:workspace_updated, _}
    end

    test "agents cannot change the name or slug, whatever the owner's role",
         %{ws: ws, scopes: scopes} do
      agent = %Actor{id: -1, workspace_id: ws.id, kind: :agent, owner_id: scopes.owner.user.id}
      scope = %{scopes.owner | actor: agent}

      assert {:error, :forbidden} = Workspaces.update(scope, %{slug: "acme-cn"})
      assert {:error, :forbidden} = Workspaces.update(scope, %{name: "New"})
      refute_receive {:workspace_updated, _}
    end

    test "a validation failure broadcasts nothing", %{ws: ws, scopes: scopes} do
      assert {:error, %Ecto.Changeset{}} = Workspaces.update(scopes.owner, %{name: "  "})
      assert {:error, %Ecto.Changeset{}} = Workspaces.update(scopes.owner, %{slug: "-bad"})
      assert %Workspace{slug: "acme", name: "Acme"} = Repo.reload!(ws)
      refute_receive {:workspace_updated, _}
    end

    test "values that cannot be cast are rejected even without other changes",
         %{ws: ws, scopes: scopes} do
      assert {:error, changeset} = Workspaces.update(scopes.owner, %{name: []})
      assert %{name: ["is invalid"]} = errors_on(changeset)
      assert {:error, changeset} = Workspaces.update(scopes.owner, %{slug: []})
      assert %{slug: ["is invalid"]} = errors_on(changeset)
      assert %Workspace{slug: "acme", name: "Acme"} = Repo.reload!(ws)
      refute_receive {:workspace_updated, _}
    end

    test "a valid and an invalid field together are rejected as a whole",
         %{ws: ws, scopes: scopes} do
      assert {:error, %Ecto.Changeset{}} =
               Workspaces.update(scopes.owner, %{name: "New", slug: "-bad"})

      assert {:error, %Ecto.Changeset{}} =
               Workspaces.update(scopes.owner, %{name: "New", slug: []})

      assert %Workspace{slug: "acme", name: "Acme"} = Repo.reload!(ws)
      refute_receive {:workspace_updated, _}
    end

    test "resubmitting the current values succeeds without a notification",
         %{ws: ws, scopes: scopes} do
      assert {:ok, %Workspace{name: "Acme", slug: "acme"}} =
               Workspaces.update(scopes.owner, %{name: "Acme", slug: "ACME"})

      assert Repo.reload!(ws).updated_at == ws.updated_at
      refute_receive {:workspace_updated, _}
    end

    test "an outer rollback drops the notification and the change", %{ws: ws, scopes: scopes} do
      assert {:error, :later_step_failed} =
               Tx.run(fn ->
                 {:ok, _} = Workspaces.update(scopes.owner, %{name: "Inside"})
                 {:error, :later_step_failed}
               end)

      assert Repo.reload!(ws).name == "Acme"
      refute_receive {:workspace_updated, _}
    end

    test "an outer commit sends the notification afterwards", %{ws: ws, scopes: scopes} do
      assert {:ok, :done} =
               Tx.run(fn ->
                 {:ok, _} = Workspaces.update(scopes.owner, %{name: "Inside"})
                 refute_received {:workspace_updated, _}
                 {:ok, :done}
               end)

      assert_received {:workspace_updated, %{name: "Inside"}}
      assert Repo.reload!(ws).name == "Inside"
    end
  end
end
