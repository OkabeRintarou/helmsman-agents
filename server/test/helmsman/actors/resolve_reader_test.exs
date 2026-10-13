defmodule Helmsman.Actors.ResolveReaderTest do
  # add-rest-api decision 3: the current identity of a REST read.
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
      off: agent_fixture(workspace, alice, "keel/off", %{disabled_at: DateTime.utc_now(:second)}),
      bobs: agent_fixture(workspace, bob, "bob/dev"),
      bob_human: Actors.get_human(workspace.id, bob.id),
      alice_human: Actors.get_human(workspace.id, alice.id)
    }
  end

  defp scope(user, ws, default_agent \\ nil) do
    token = %ApiToken{
      workspace_id: ws.id,
      user_id: user.id,
      default_agent_id: default_agent && default_agent.id
    }

    token_scope_fixture(user, ws, :api, token)
  end

  test "a requested agent of the user's own, even disabled", ctx do
    %{alice: alice, workspace: ws, keel: keel, off: off} = ctx

    assert {:ok, actor, :requested} = Actors.resolve_reader(scope(alice, ws), "keel/dev")
    assert actor.id == keel.id

    assert {:ok, actor, :requested} = Actors.resolve_reader(scope(alice, ws, keel), "keel/off")
    assert actor.id == off.id
  end

  test "someone else's agent, a human or an unknown name is forbidden", ctx do
    %{alice: alice, workspace: ws, bobs: bobs, bob_human: bob_human, alice_human: own} = ctx

    for name <- [bobs.name, bob_human.name, own.name, "nobody/here"] do
      assert Actors.resolve_reader(scope(alice, ws), name) == {:error, :forbidden}, name
    end
  end

  test "without a name: the token's default agent, even disabled", ctx do
    %{alice: alice, workspace: ws, keel: keel, off: off} = ctx

    assert {:ok, actor, :default} = Actors.resolve_reader(scope(alice, ws, keel), nil)
    assert actor.id == keel.id

    assert {:ok, actor, :default} = Actors.resolve_reader(scope(alice, ws, off), nil)
    assert actor.id == off.id
  end

  test "a default agent that is no longer the user's is forbidden", ctx do
    %{alice: alice, workspace: ws, bobs: bobs} = ctx
    assert Actors.resolve_reader(scope(alice, ws, bobs), nil) == {:error, :forbidden}
  end

  test "without a name or default agent: the user's human identity", ctx do
    %{alice: alice, workspace: ws, alice_human: human} = ctx

    assert {:ok, actor, :human} = Actors.resolve_reader(scope(alice, ws), nil)
    assert actor.id == human.id
  end

  test "works outside a transaction and takes no lock", ctx do
    %{alice: alice, workspace: ws} = ctx
    refute Repo.in_transaction?()
    assert {:ok, _actor, :human} = Actors.resolve_reader(scope(alice, ws), nil)
    assert {:ok, _actor, :requested} = Actors.resolve_reader(scope(alice, ws), "keel/dev")
  end
end
