defmodule Helmsman.Actors.IdentifyRaceTest do
  # identify runs concurrently with other identifies, an import and a
  # member removal, each committing on its own connection outside the
  # sandbox.
  use ExUnit.Case, async: false

  import Ecto.Query
  import Helmsman.AccountsFixtures
  import Helmsman.ApiTokensFixtures
  import Helmsman.WorkspacesFixtures

  alias Helmsman.Actors
  alias Helmsman.Actors.Actor
  alias Helmsman.CommittedData
  alias Helmsman.Locks
  alias Helmsman.Repo
  alias Helmsman.Tx

  setup do
    tag = System.unique_integer([:positive])

    {owner, alice, bob, workspace} =
      CommittedData.unboxed(fn ->
        owner = user_fixture(%{email: "owner-#{tag}@identify.test"})
        alice = user_fixture(%{email: "alice-#{tag}@identify.test"})
        bob = user_fixture(%{email: "bob-#{tag}@identify.test"})
        workspace = workspace_fixture(owner)
        member_fixture(workspace, alice, :member)
        member_fixture(workspace, bob, :member)
        {owner, alice, bob, workspace}
      end)

    on_exit(fn -> CommittedData.delete_user_data!([owner.id, alice.id, bob.id]) end)

    CommittedData.unboxed(fn ->
      %{
        workspace: workspace,
        alice_scope: token_scope_fixture(alice, workspace, :mcp),
        bob_scope: token_scope_fixture(bob, workspace, :mcp)
      }
    end)
  end

  defp agents(workspace, name) do
    CommittedData.unboxed(fn ->
      Repo.all(from(a in Actor, where: a.workspace_id == ^workspace.id and a.name == ^name))
    end)
  end

  # Runs `fun` on its own connection after reporting the connection's
  # backend pid as `{:backend, pid}`.
  defp start(parent, fun) do
    Task.async(fn ->
      CommittedData.unboxed(fn ->
        send(parent, {:backend, CommittedData.backend_pid()})
        fun.()
      end)
    end)
  end

  # Identifies inside an outer transaction that stays open until :commit.
  defp start_holding_identify(parent, scope, name) do
    start(parent, fn ->
      Tx.run(fn ->
        result = Actors.identify(scope, %{name: name})
        send(parent, :identified)

        receive do
          :commit -> result
        end
      end)
    end)
  end

  defp start_identify(parent, scope, name) do
    task = start(parent, fn -> Actors.identify(scope, %{name: name}) end)
    assert_receive {:backend, pid}, 5_000
    CommittedData.await_lock_wait(pid)
    task
  end

  test "the same user identifying the same new name twice gets one identity",
       %{alice_scope: scope, workspace: ws} do
    parent = self()
    holder = start_holding_identify(parent, scope, "keel/dev")
    assert_receive {:backend, _pid}, 5_000
    assert_receive :identified, 5_000

    # The second insert waits on the first one's uncommitted row.
    waiter = start_identify(parent, scope, "keel/dev")

    send(holder.pid, :commit)
    assert {:ok, first} = Task.await(holder)
    assert {:ok, second} = Task.await(waiter)

    assert first.id == second.id
    assert [%Actor{kind: :agent}] = agents(ws, "keel/dev")
  end

  test "two users identifying the same new name: one wins, the other is name_taken",
       %{alice_scope: alice, bob_scope: bob, workspace: ws} do
    parent = self()
    holder = start_holding_identify(parent, alice, "keel/dev")
    assert_receive {:backend, _pid}, 5_000
    assert_receive :identified, 5_000

    waiter = start_identify(parent, bob, "keel/dev")

    send(holder.pid, :commit)
    assert {:ok, agent} = Task.await(holder)
    assert Task.await(waiter) == {:error, :name_taken}

    assert [%Actor{id: id, owner_id: owner_id}] = agents(ws, "keel/dev")
    assert {id, owner_id} == {agent.id, alice.user.id}
  end

  test "identify waits for an import holding the exclusive maintenance lock",
       %{alice_scope: scope, workspace: ws} do
    parent = self()

    import_task =
      start(parent, fn ->
        Repo.transact(fn ->
          Locks.maint_exclusive!(ws.id)
          send(parent, :locked)

          receive do
            :release -> {:ok, :imported}
          end
        end)
      end)

    assert_receive {:backend, _pid}, 5_000
    assert_receive :locked, 5_000

    waiter = start_identify(parent, scope, "keel/dev")
    assert agents(ws, "keel/dev") == []

    send(import_task.pid, :release)
    assert {:ok, :imported} = Task.await(import_task)
    assert {:ok, %Actor{name: "keel/dev"}} = Task.await(waiter)
    assert [_] = agents(ws, "keel/dev")
  end

  test "identify with a scope from before a removal waits for it and is not_found",
       %{alice_scope: scope, workspace: ws} do
    parent = self()

    removal =
      start(parent, fn ->
        Repo.transact(fn ->
          %{num_rows: 1} =
            Repo.query!(
              "DELETE FROM memberships WHERE workspace_id = $1 AND user_id = $2",
              [ws.id, scope.user.id]
            )

          send(parent, :deleted)

          receive do
            :commit -> {:ok, :removed}
          end
        end)
      end)

    assert_receive {:backend, _pid}, 5_000
    assert_receive :deleted, 5_000

    waiter = start_identify(parent, scope, "keel/dev")

    send(removal.pid, :commit)
    assert {:ok, :removed} = Task.await(removal)
    assert Task.await(waiter) == {:error, :not_found}
    assert agents(ws, "keel/dev") == []
  end
end
