defmodule Helmsman.Actors.ResolveWriterTest do
  use Helmsman.DataCase, async: true

  import Helmsman.AccountsFixtures
  import Helmsman.ApiTokensFixtures
  import Helmsman.WorkspacesFixtures

  alias Helmsman.Actors
  alias Helmsman.ApiTokens.ApiToken

  setup do
    owner = user_fixture()
    workspace = workspace_fixture(owner)
    alice = user_fixture()
    bob = user_fixture()
    member_fixture(workspace, alice, :member)
    member_fixture(workspace, bob, :member)

    %{
      workspace: workspace,
      alice: alice,
      keel: agent_fixture(workspace, alice, "keel/dev"),
      review: agent_fixture(workspace, alice, "keel/review"),
      bobs: agent_fixture(workspace, bob, "bob/dev")
    }
  end

  defp scope(user, ws, via, default_agent \\ nil) do
    token = %ApiToken{
      workspace_id: ws.id,
      user_id: user.id,
      default_agent_id: default_agent && default_agent.id
    }

    token_scope_fixture(user, ws, via, token)
  end

  defp disable!(agent) do
    agent |> Ecto.Changeset.change(disabled_at: DateTime.utc_now(:second)) |> Repo.update!()
  end

  describe "an explicitly requested actor" do
    test "an agent of the user's own is used", %{
      alice: alice,
      workspace: ws,
      keel: keel,
      review: review
    } do
      for via <- [:api, :mcp] do
        assert {:ok, actor} =
                 Actors.resolve_writer(scope(alice, ws, via, review), requested: "keel/dev")

        assert actor.id == keel.id
      end
    end

    test "someone else's agent is forbidden", %{alice: alice, workspace: ws} do
      assert Actors.resolve_writer(scope(alice, ws, :api), requested: "bob/dev") ==
               {:error, :forbidden}
    end

    test "unknown names, humans (one's own too) and the system identity are forbidden",
         %{alice: alice, workspace: ws} do
      own_human = Actors.get_human(ws.id, alice.id).name

      for name <- ["nobody/dev", own_human, "helmsman"] do
        assert Actors.resolve_writer(scope(alice, ws, :api), requested: name) ==
                 {:error, :forbidden}
      end
    end

    test "a disabled agent of the user's own is agent_disabled",
         %{alice: alice, workspace: ws, keel: keel} do
      disable!(keel)

      assert Actors.resolve_writer(scope(alice, ws, :api), requested: "keel/dev") ==
               {:error, {:agent_disabled, "keel/dev"}}
    end
  end

  describe "the MCP session identity" do
    test "comes before the token's default agent",
         %{alice: alice, workspace: ws, keel: keel, review: review} do
      assert {:ok, actor} =
               Actors.resolve_writer(scope(alice, ws, :mcp, keel), session_actor_id: review.id)

      assert actor.id == review.id
    end

    test "must still be an active agent of the user's own",
         %{alice: alice, workspace: ws, review: review, bobs: bobs} do
      assert Actors.resolve_writer(scope(alice, ws, :mcp), session_actor_id: bobs.id) ==
               {:error, :forbidden}

      disable!(review)

      assert Actors.resolve_writer(scope(alice, ws, :mcp), session_actor_id: review.id) ==
               {:error, {:agent_disabled, "keel/review"}}
    end
  end

  describe "the token's default agent" do
    test "is used without a requested actor", %{alice: alice, workspace: ws, keel: keel} do
      for via <- [:api, :mcp] do
        assert {:ok, actor} = Actors.resolve_writer(scope(alice, ws, via, keel), [])
        assert actor.id == keel.id
      end
    end

    test "disabled after the token was created is refused",
         %{alice: alice, workspace: ws, keel: keel} do
      disable!(keel)

      assert Actors.resolve_writer(scope(alice, ws, :api, keel), []) ==
               {:error, {:agent_disabled, "keel/dev"}}
    end
  end

  describe "without any of the above" do
    test "REST falls back to the user's human identity", %{alice: alice, workspace: ws} do
      assert {:ok, actor} = Actors.resolve_writer(scope(alice, ws, :api), [])
      assert actor.id == Actors.get_human(ws.id, alice.id).id
    end

    test "MCP needs a session agent", %{alice: alice, workspace: ws} do
      assert Actors.resolve_writer(scope(alice, ws, :mcp), []) == {:error, :needs_session_agent}

      assert Actors.resolve_writer(token_scope_fixture(alice, ws, :mcp), []) ==
               {:error, :needs_session_agent}
    end
  end
end
