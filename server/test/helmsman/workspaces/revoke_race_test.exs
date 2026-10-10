defmodule Helmsman.Workspaces.RevokeRaceTest do
  # Writes and role changes commit on separate connections outside the
  # sandbox.
  use ExUnit.Case, async: false

  import Ecto.Query
  import Helmsman.AccountsFixtures
  import Helmsman.WorkspacesFixtures

  alias Helmsman.CommittedData
  alias Helmsman.Repo
  alias Helmsman.Workspaces
  alias Helmsman.Workspaces.Workspace

  setup do
    tag = System.unique_integer([:positive])

    {owner, alice, workspace} =
      CommittedData.unboxed(fn ->
        owner = user_fixture(%{email: "owner-#{tag}@revoke.test"})
        alice = user_fixture(%{email: "alice-#{tag}@revoke.test"})
        workspace = workspace_fixture(owner, %{name: "Before"})
        member_fixture(workspace, alice, :admin)
        {owner, alice, workspace}
      end)

    on_exit(fn -> CommittedData.delete_user_data!([owner.id, alice.id]) end)

    scope = CommittedData.unboxed(fn -> workspace_scope_fixture(alice, workspace) end)
    %{scope: scope, alice: alice, workspace: workspace}
  end

  test "a demotion waits for a write that already passed the check",
       %{scope: scope, alice: alice, workspace: ws} do
    writer = start_writer(scope, [])
    assert_receive :checked, 5_000

    # The membership row is share-locked by the uncommitted write.
    assert {:error, %Postgrex.Error{postgres: %{code: :lock_not_available}}} =
             demote(ws, alice, "200ms")

    send(writer.pid, :commit)
    assert {:ok, _} = Task.await(writer)

    assert {:ok, %{num_rows: 1}} = demote(ws, alice, "2s")
    assert committed_name(ws) == "During"
  end

  test "a write that starts after a committed demotion is forbidden",
       %{scope: scope, alice: alice, workspace: ws} do
    assert {:ok, %{num_rows: 1}} = demote(ws, alice, "2s")

    assert {:error, :forbidden} =
             CommittedData.unboxed(fn ->
               Workspaces.write_transaction(scope, :update_workspace, &rename_to_during/1)
             end)

    assert committed_name(ws) == "Before"
  end

  # Contrast for the test above: without the shared lock (as member
  # management runs before taking its own locks) the demotion commits while
  # the already-checked write is still open, so the write commits after the
  # revocation.
  test "without FOR SHARE the write commits after the revocation",
       %{scope: scope, alice: alice, workspace: ws} do
    writer = start_writer(scope, membership_lock: :none)
    assert_receive :checked, 5_000

    assert {:ok, %{num_rows: 1}} = demote(ws, alice, "200ms")

    send(writer.pid, :commit)
    assert {:ok, _} = Task.await(writer)
    assert committed_name(ws) == "During"
  end

  # Starts an update_workspace write that passes the membership check and
  # waits for :commit before returning.
  defp start_writer(scope, opts) do
    parent = self()
    Task.async(fn -> CommittedData.unboxed(fn -> write_and_wait(parent, scope, opts) end) end)
  end

  defp write_and_wait(parent, scope, opts) do
    Workspaces.write_transaction(
      scope,
      :update_workspace,
      nil,
      &rename_and_wait(parent, &1),
      opts
    )
  end

  defp rename_and_wait(parent, scope) do
    result = rename_to_during(scope)
    send(parent, :checked)

    receive do
      :commit -> result
    end
  end

  defp rename_to_during(scope) do
    {1, _} =
      Repo.update_all(from(w in Workspace, where: w.id == ^scope.workspace.id),
        set: [name: "During"]
      )

    {:ok, :renamed}
  end

  defp demote(ws, user, lock_timeout) do
    CommittedData.unboxed(fn ->
      Repo.transact(fn ->
        Repo.query!("SET LOCAL lock_timeout = '#{lock_timeout}'")

        Repo.query(
          "UPDATE memberships SET role = 'viewer' WHERE workspace_id = $1 AND user_id = $2",
          [ws.id, user.id]
        )
      end)
    end)
  end

  defp committed_name(ws) do
    CommittedData.unboxed(fn ->
      Repo.one!(from(w in Workspace, where: w.id == ^ws.id, select: w.name))
    end)
  end
end
