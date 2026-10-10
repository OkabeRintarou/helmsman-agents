defmodule Helmsman.Actors.IdentifyTest do
  use Helmsman.DataCase, async: true

  import Helmsman.AccountsFixtures
  import Helmsman.ApiTokensFixtures
  import Helmsman.WorkspacesFixtures

  alias Helmsman.Actors
  alias Helmsman.Actors.Actor
  alias Helmsman.Workspaces.Membership

  setup do
    owner = user_fixture()
    workspace = workspace_fixture(owner)
    alice = user_fixture(%{email: "alice@example.com"})
    bob = user_fixture()
    member_fixture(workspace, alice, :member)
    member_fixture(workspace, bob, :member)

    %{
      workspace: workspace,
      alice: alice,
      bob: bob,
      alice_scope: token_scope_fixture(alice, workspace, :mcp),
      bob_scope: token_scope_fixture(bob, workspace, :mcp)
    }
  end

  defp actors_snapshot(workspace) do
    Repo.all(from(a in Actor, where: a.workspace_id == ^workspace.id, order_by: a.id))
  end

  test "the first identify creates an agent owned by the token's user",
       %{alice_scope: scope, alice: alice, workspace: ws} do
    assert {:ok, %Actor{} = agent} =
             Actors.identify(scope, %{name: "keel/dev", project: "KEEL", worktree: "wt-1"})

    assert agent.kind == :agent
    assert agent.name == "keel/dev"
    assert agent.owner_id == alice.id
    assert agent.workspace_id == ws.id
    assert agent.project_key == "KEEL"
    assert agent.worktree == "wt-1"
    assert %DateTime{} = agent.last_seen_at
    assert Repo.get!(Actor, agent.id).worktree == "wt-1"
  end

  test "identify again reuses the agent and updates worktree and last_seen_at",
       %{alice_scope: scope} do
    {:ok, first} = Actors.identify(scope, %{name: "keel/dev", project: "KEEL", worktree: "wt-1"})

    assert {:ok, again} =
             Actors.identify(scope, %{name: "keel/dev", project: nil, worktree: "wt-2"})

    assert again.id == first.id
    assert again.worktree == "wt-2"
    assert again.project_key == "KEEL"
    assert DateTime.compare(again.last_seen_at, first.last_seen_at) == :gt
    assert Repo.get!(Actor, first.id).worktree == "wt-2"
  end

  test "someone else's agent is name_taken", %{alice_scope: alice, bob_scope: bob} do
    {:ok, _} = Actors.identify(alice, %{name: "keel/dev"})
    assert Actors.identify(bob, %{name: "keel/dev"}) == {:error, :name_taken}
  end

  test "human identities, the user's own included, and the system identity are name_taken",
       %{alice_scope: scope, bob: bob, workspace: ws} do
    for name <- ["alice", Actors.get_human(ws.id, bob.id).name, "helmsman"] do
      assert Actors.identify(scope, %{name: name}) == {:error, :name_taken}
    end
  end

  test "a disabled agent of the user's own is agent_disabled",
       %{alice_scope: scope, alice: alice, workspace: ws} do
    agent_fixture(ws, alice, "keel/old", %{disabled_at: DateTime.utc_now(:second)})
    before = actors_snapshot(ws)

    assert Actors.identify(scope, %{name: "keel/old", worktree: "wt-9"}) ==
             {:error, :agent_disabled}

    assert actors_snapshot(ws) == before
  end

  test "an invalid name is an error", %{alice_scope: scope, workspace: ws} do
    before = actors_snapshot(ws)

    for name <- ["Keel/Dev", "/keel", "", nil, String.duplicate("a", 65)] do
      assert {:error, %Ecto.Changeset{} = changeset} = Actors.identify(scope, %{name: name})
      assert %{name: [_]} = errors_on(changeset)
    end

    assert actors_snapshot(ws) == before
  end

  test "an invalid case variant of an existing agent's name is an error, not a reuse",
       %{alice_scope: scope, workspace: ws} do
    {:ok, agent} = Actors.identify(scope, %{name: "keel/dev", project: "KEEL", worktree: "wt-1"})
    before = actors_snapshot(ws)

    for name <- ["Keel/Dev", "KEEL/DEV"] do
      assert {:error, %Ecto.Changeset{} = changeset} =
               Actors.identify(scope, %{name: name, project: "OTHER", worktree: "wt-2"})

      assert %{name: [_]} = errors_on(changeset)
    end

    assert actors_snapshot(ws) == before
    current = Repo.get!(Actor, agent.id)
    assert {current.project_key, current.worktree} == {"KEEL", "wt-1"}
    assert current.last_seen_at == agent.last_seen_at
  end

  test "a viewer can neither create nor reuse an identity",
       %{alice_scope: scope, alice: alice, workspace: ws} do
    {:ok, _} = Actors.identify(scope, %{name: "keel/dev", worktree: "wt-1"})

    Repo.update_all(
      from(m in Membership, where: m.workspace_id == ^ws.id and m.user_id == ^alice.id),
      set: [role: :viewer]
    )

    before = actors_snapshot(ws)

    assert Actors.identify(scope, %{name: "keel/dev", worktree: "wt-2"}) == {:error, :forbidden}
    assert Actors.identify(scope, %{name: "keel/new"}) == {:error, :forbidden}
    assert actors_snapshot(ws) == before
  end

  test "after the membership is gone identify is not_found and writes nothing",
       %{alice_scope: scope, alice: alice, workspace: ws} do
    {:ok, _} = Actors.identify(scope, %{name: "keel/dev", worktree: "wt-1"})

    Repo.delete_all(
      from(m in Membership, where: m.workspace_id == ^ws.id and m.user_id == ^alice.id)
    )

    before = actors_snapshot(ws)

    assert Actors.identify(scope, %{name: "keel/dev", worktree: "wt-2"}) == {:error, :not_found}
    assert Actors.identify(scope, %{name: "keel/new"}) == {:error, :not_found}
    assert actors_snapshot(ws) == before
  end

  test "an agent of the user's may identify (not a management action)",
       %{alice_scope: scope, alice: alice, workspace: ws} do
    agent = agent_fixture(ws, alice, "keel/dev")

    assert {:ok, %Actor{name: "keel/review", owner_id: owner_id}} =
             Actors.identify(%{scope | actor: agent}, %{name: "keel/review"})

    assert owner_id == alice.id
  end
end
