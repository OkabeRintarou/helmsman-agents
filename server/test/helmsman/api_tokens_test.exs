defmodule Helmsman.ApiTokensTest do
  use Helmsman.DataCase, async: true

  import Helmsman.AccountsFixtures
  import Helmsman.ApiTokensFixtures
  import Helmsman.WorkspacesFixtures

  alias Helmsman.Actors
  alias Helmsman.ApiTokens
  alias Helmsman.ApiTokens.ApiToken
  alias Helmsman.Workspaces.Membership

  setup do
    owner = user_fixture()
    workspace = workspace_fixture(owner)

    [alice, bob, admin, viewer] =
      for role <- [:member, :member, :admin, :viewer] do
        user = user_fixture()
        member_fixture(workspace, user, role)
        user
      end

    %{
      workspace: workspace,
      alice: alice,
      bob: bob,
      admin: admin,
      viewer: viewer,
      alice_scope: workspace_scope_fixture(alice, workspace),
      bob_scope: workspace_scope_fixture(bob, workspace),
      admin_scope: workspace_scope_fixture(admin, workspace),
      viewer_scope: workspace_scope_fixture(viewer, workspace)
    }
  end

  defp set_role(workspace, user, role) do
    Repo.update_all(
      from(m in Membership, where: m.workspace_id == ^workspace.id and m.user_id == ^user.id),
      set: [role: role]
    )
  end

  defp token_count, do: Repo.aggregate(ApiToken, :count)

  describe "create/2" do
    test "a member creates a token; the plaintext is returned once", %{alice_scope: scope} do
      assert {:ok, %{token: token, api_token: api_token}} =
               ApiTokens.create(scope, %{name: "laptop", scopes: ["mcp"]})

      assert "hm_" <> random = token
      assert random =~ ~r/^[a-z2-7]{52}$/
      assert api_token.name == "laptop"
      assert api_token.scopes == ["mcp"]
      assert api_token.user_id == scope.user.id
      assert api_token.workspace_id == scope.workspace.id
      assert is_nil(api_token.revoked_at)

      # No later read hands the plaintext back.
      {:ok, listed} = ApiTokens.list_own(scope)
      refute inspect(listed, limit: :infinity) =~ random
    end

    test "only the hash and the prefix are stored", %{alice_scope: scope} do
      %{token: token, api_token: %{id: id}} = api_token_fixture(scope)
      "hm_" <> random = token

      stored = Repo.get!(ApiToken, id)
      assert stored.token_hash == :crypto.hash(:sha256, token)
      assert stored.prefix == binary_part(random, 0, 8)

      %{rows: [row]} = Repo.query!("SELECT * FROM api_tokens WHERE id = $1", [id])

      for value <- row, is_binary(value) do
        refute value =~ random
        refute value =~ binary_part(random, 8, 44)
      end
    end

    test "a viewer cannot create a token", %{viewer_scope: scope} do
      assert ApiTokens.create(scope, %{name: "laptop", scopes: ["mcp"]}) == {:error, :forbidden}
      assert token_count() == 0
    end

    test "a request acting as an agent cannot create a token",
         %{alice_scope: scope, alice: alice, workspace: ws} do
      agent = agent_fixture(ws, alice, "keel/dev")

      assert ApiTokens.create(%{scope | actor: agent}, %{name: "laptop", scopes: ["mcp"]}) ==
               {:error, :forbidden}
    end

    test "the role is re-read from the database", %{
      alice_scope: scope,
      alice: alice,
      workspace: ws
    } do
      set_role(ws, alice, :viewer)
      assert ApiTokens.create(scope, %{name: "laptop", scopes: ["mcp"]}) == {:error, :forbidden}
    end

    test "the default agent must be an active agent of the creator's own",
         %{alice_scope: scope, alice: alice, bob: bob, workspace: ws} do
      bobs = agent_fixture(ws, bob, "bob/dev")
      disabled = agent_fixture(ws, alice, "alice/old", %{disabled_at: DateTime.utc_now(:second)})
      human = Actors.get_human(ws.id, alice.id)

      for agent <- [bobs, disabled, human] do
        assert {:error, changeset} =
                 ApiTokens.create(scope, %{
                   name: "laptop",
                   scopes: ["mcp"],
                   default_agent_id: agent.id
                 })

        assert %{default_agent_id: ["must be an active agent of your own"]} =
                 errors_on(changeset)
      end

      own = agent_fixture(ws, alice, "keel/dev")

      assert {:ok, %{api_token: %{default_agent_id: id}}} =
               ApiTokens.create(scope, %{
                 name: "laptop",
                 scopes: ["mcp"],
                 default_agent_id: own.id
               })

      assert id == own.id
    end

    test "the default agent cannot come from another workspace",
         %{alice_scope: scope, alice: alice} do
      other = workspace_fixture(alice)
      foreign = agent_fixture(other, alice, "keel/dev")

      assert {:error, changeset} =
               ApiTokens.create(scope, %{
                 name: "laptop",
                 scopes: ["mcp"],
                 default_agent_id: foreign.id
               })

      assert %{default_agent_id: [_]} = errors_on(changeset)
    end

    test "empty or unknown scopes fail and list the valid ones", %{alice_scope: scope} do
      for scopes <- [[], ["admin"]] do
        assert {:error, changeset} = ApiTokens.create(scope, %{name: "laptop", scopes: scopes})

        assert %{scopes: ["must be one or more of: mcp, api:read, api:write"]} =
                 errors_on(changeset)
      end

      assert token_count() == 0
    end
  end

  describe "list_own/1 and list_all/1" do
    test "everyone lists their own tokens; admins list all",
         %{alice_scope: alice, bob_scope: bob, admin_scope: admin, viewer_scope: viewer} do
      %{api_token: a} = api_token_fixture(alice)
      %{api_token: b} = api_token_fixture(bob)

      assert {:ok, [%ApiToken{id: id, default_agent: nil}]} = ApiTokens.list_own(alice)
      assert id == a.id
      assert {:ok, []} = ApiTokens.list_own(viewer)

      assert {:ok, all} = ApiTokens.list_all(admin)
      assert Enum.map(all, & &1.id) == [b.id, a.id]
      assert Enum.all?(all, &match?(%ApiToken{user: %{}}, &1))

      assert ApiTokens.list_all(alice) == {:error, :forbidden}
      assert ApiTokens.list_all(viewer) == {:error, :forbidden}
    end

    test "tokens of other workspaces are never listed", %{alice: alice, alice_scope: scope} do
      other = workspace_fixture(alice)
      api_token_fixture(workspace_scope_fixture(alice, other))

      assert {:ok, []} = ApiTokens.list_own(scope)
    end
  end

  describe "revoke/2" do
    test "revoking one's own token takes effect immediately", %{alice_scope: scope} do
      %{token: token, api_token: api_token} = api_token_fixture(scope)
      assert {:ok, _} = ApiTokens.authenticate(token, "mcp")

      assert {:ok, %ApiToken{revoked_at: %DateTime{}}} = ApiTokens.revoke(scope, api_token.id)
      assert ApiTokens.authenticate(token, "mcp") == {:error, :unauthorized}

      # Revoking again is a no-op.
      assert {:ok, %ApiToken{revoked_at: %DateTime{}}} =
               ApiTokens.revoke(scope, to_string(api_token.id))
    end

    test "a member cannot revoke someone else's token",
         %{alice_scope: alice, bob_scope: bob} do
      %{token: token, api_token: api_token} = api_token_fixture(bob)

      assert ApiTokens.revoke(alice, api_token.id) == {:error, :forbidden}
      assert {:ok, _} = ApiTokens.authenticate(token, "mcp")
    end

    test "an admin revokes someone else's token", %{admin_scope: admin, bob_scope: bob} do
      %{token: token, api_token: api_token} = api_token_fixture(bob)

      assert {:ok, %ApiToken{revoked_at: %DateTime{}}} = ApiTokens.revoke(admin, api_token.id)
      assert ApiTokens.authenticate(token, "mcp") == {:error, :unauthorized}
    end

    test "a user demoted to viewer still revokes their own tokens, nobody else's",
         %{alice_scope: alice, alice: alice_user, bob_scope: bob, workspace: ws} do
      %{token: own_token, api_token: own} = api_token_fixture(alice)
      %{api_token: bobs} = api_token_fixture(bob)
      set_role(ws, alice_user, :viewer)

      assert {:ok, %ApiToken{revoked_at: %DateTime{}}} = ApiTokens.revoke(alice, own.id)
      assert ApiTokens.authenticate(own_token, "mcp") == {:error, :unauthorized}
      assert ApiTokens.revoke(alice, bobs.id) == {:error, :forbidden}
    end

    test "a request acting as an agent cannot revoke tokens",
         %{alice_scope: scope, alice: alice, workspace: ws} do
      %{api_token: api_token} = api_token_fixture(scope)
      agent = agent_fixture(ws, alice, "keel/dev")

      assert ApiTokens.revoke(%{scope | actor: agent}, api_token.id) == {:error, :forbidden}
    end

    test "unknown tokens and tokens of other workspaces are not found",
         %{admin: admin, admin_scope: scope} do
      other = workspace_fixture(admin)
      %{api_token: foreign} = api_token_fixture(workspace_scope_fixture(admin, other))

      assert ApiTokens.revoke(scope, foreign.id) == {:error, :not_found}
      assert ApiTokens.revoke(scope, -1) == {:error, :not_found}
      assert ApiTokens.revoke(scope, "nope") == {:error, :not_found}
    end
  end

  describe "authenticate/2" do
    setup %{alice_scope: scope} do
      %{token: token, api_token: api_token} =
        api_token_fixture(scope, %{scopes: ["mcp", "api:read"]})

      %{token: token, api_token: api_token}
    end

    test "a valid token returns the token, user, workspace and current role",
         %{token: token, api_token: api_token, alice: alice, workspace: ws} do
      assert {:ok, found} = ApiTokens.authenticate(token, "mcp")
      assert found.token.id == api_token.id
      assert found.user.id == alice.id
      assert found.workspace.id == ws.id
      assert found.role == :member

      set_role(ws, alice, :admin)
      assert {:ok, %{role: :admin}} = ApiTokens.authenticate(token, "api:read")
    end

    test "malformed tokens", %{token: token} do
      for bad <- [
            "",
            "hm_",
            "hm_short",
            token <> "a",
            binary_part(token, 0, 54),
            "xx_" <> binary_part(token, 3, 52)
          ] do
        assert ApiTokens.authenticate(bad, "mcp") == {:error, :unauthorized}
      end
    end

    test "an unknown token" do
      unknown =
        "hm_" <> Base.encode32(:crypto.strong_rand_bytes(32), case: :lower, padding: false)

      assert ApiTokens.authenticate(unknown, "mcp") == {:error, :unauthorized}
    end

    test "a revoked token", %{token: token, api_token: api_token} do
      Repo.update_all(from(t in ApiToken, where: t.id == ^api_token.id),
        set: [revoked_at: DateTime.utc_now(:second)]
      )

      assert ApiTokens.authenticate(token, "mcp") == {:error, :unauthorized}
    end

    test "an expired token", %{token: token, api_token: api_token} do
      set_expiry = fn at ->
        Repo.update_all(from(t in ApiToken, where: t.id == ^api_token.id), set: [expires_at: at])
      end

      set_expiry.(DateTime.add(DateTime.utc_now(:second), 3600))
      assert {:ok, _} = ApiTokens.authenticate(token, "mcp")

      set_expiry.(DateTime.add(DateTime.utc_now(:second), -1))
      assert ApiTokens.authenticate(token, "mcp") == {:error, :unauthorized}
    end

    test "a token whose user is no longer a member", %{token: token, alice: alice, workspace: ws} do
      Repo.delete_all(
        from(m in Membership, where: m.workspace_id == ^ws.id and m.user_id == ^alice.id)
      )

      assert ApiTokens.authenticate(token, "mcp") == {:error, :unauthorized}
    end

    test "a token without the required scope", %{token: token} do
      assert ApiTokens.authenticate(token, "api:write") == {:error, :insufficient_scope}
    end
  end
end
