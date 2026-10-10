defmodule Helmsman.Workspaces.WriteTransactionTest do
  use Helmsman.DataCase, async: true

  import ExUnit.CaptureLog
  import Helmsman.AccountsFixtures
  import Helmsman.WorkspacesFixtures

  alias Helmsman.Workspaces
  alias Helmsman.Workspaces.{Membership, Workspace}

  setup do
    owner = user_fixture()
    admin = user_fixture()
    workspace = workspace_fixture(owner)
    membership = member_fixture(workspace, admin, :admin)
    %{workspace: workspace, admin: admin, membership: membership}
  end

  defp pg_error(code) do
    %Postgrex.Error{
      postgres: %{code: code, severity: "ERROR", pg_code: "test", message: "simulated"}
    }
  end

  defp deadlock, do: pg_error(:deadlock_detected)

  test "runs fun with the scope and returns its result", %{workspace: ws, admin: admin} do
    scope = workspace_scope_fixture(admin, ws)

    assert {:ok, :written} =
             Workspaces.write_transaction(scope, :update_workspace, fn scope ->
               assert scope.role == :admin
               {:ok, :written}
             end)
  end

  test "a removed membership returns :not_found without running fun",
       %{workspace: ws, admin: admin, membership: membership} do
    scope = workspace_scope_fixture(admin, ws)
    Repo.delete!(membership)

    assert {:error, :not_found} =
             Workspaces.write_transaction(scope, :view_workspace, fn _ -> flunk("ran") end)
  end

  test "a demotion is judged with the new role",
       %{workspace: ws, admin: admin, membership: membership} do
    scope = workspace_scope_fixture(admin, ws)
    Repo.update!(Ecto.Changeset.change(membership, role: :viewer))

    assert {:error, :forbidden} =
             Workspaces.write_transaction(scope, :update_workspace, fn _ -> flunk("ran") end)

    assert {:ok, :viewer} =
             Workspaces.write_transaction(scope, :view_workspace, fn scope ->
               {:ok, scope.role}
             end)
  end

  test "a deadlock is retried once", %{workspace: ws, admin: admin} do
    scope = workspace_scope_fixture(admin, ws)
    counter = :counters.new(1, [])

    assert {:ok, 2} =
             Workspaces.write_transaction(scope, :update_workspace, fn _ ->
               :counters.add(counter, 1, 1)
               if :counters.get(counter, 1) == 1, do: raise(deadlock())
               {:ok, :counters.get(counter, 1)}
             end)
  end

  test "a second deadlock or serialization failure returns an error",
       %{workspace: ws, admin: admin} do
    scope = workspace_scope_fixture(admin, ws)

    for code <- [:deadlock_detected, :serialization_failure] do
      counter = :counters.new(1, [])

      assert {:error, ^code} =
               Workspaces.write_transaction(scope, :update_workspace, fn _ ->
                 :counters.add(counter, 1, 1)
                 raise pg_error(code)
               end)

      assert :counters.get(counter, 1) == 2
    end
  end

  test "a failing after-commit callback never re-runs the committed write",
       %{workspace: ws, admin: admin} do
    scope = workspace_scope_fixture(admin, ws)
    counter = :counters.new(1, [])
    parent = self()

    log =
      capture_log(fn ->
        assert {:ok, :written} =
                 Workspaces.write_transaction(scope, :update_workspace, fn _ ->
                   :counters.add(counter, 1, 1)
                   {1, _} = Repo.update_all(where(Workspace, id: ^ws.id), set: [name: "Written"])
                   Helmsman.Tx.after_commit(fn -> raise deadlock() end)
                   Helmsman.Tx.after_commit(fn -> send(parent, :next_callback_ran) end)
                   {:ok, :written}
                 end)
      end)

    assert :counters.get(counter, 1) == 1
    assert Repo.reload!(ws).name == "Written"
    assert log =~ "after_commit callback failed after the transaction committed"
    assert_received :next_callback_ran
    # The queue is gone after the commit.
    assert_raise RuntimeError, fn -> Helmsman.Tx.after_commit(fn -> :ok end) end
  end

  test "a retried attempt drops the callbacks of the failed one",
       %{workspace: ws, admin: admin} do
    scope = workspace_scope_fixture(admin, ws)
    counter = :counters.new(1, [])
    parent = self()

    assert {:ok, nil} =
             Workspaces.write_transaction(scope, :update_workspace, fn _ ->
               :counters.add(counter, 1, 1)
               attempt = :counters.get(counter, 1)
               Helmsman.Tx.after_commit(fn -> send(parent, {:attempt, attempt}) end)
               if attempt == 1, do: raise(deadlock())
               {:ok, nil}
             end)

    assert_received {:attempt, 2}
    refute_received {:attempt, 1}
  end

  test "other errors are not retried", %{workspace: ws, admin: admin} do
    scope = workspace_scope_fixture(admin, ws)
    counter = :counters.new(1, [])

    assert_raise Postgrex.Error, fn ->
      Workspaces.write_transaction(scope, :update_workspace, fn _ ->
        :counters.add(counter, 1, 1)
        raise pg_error(:unique_violation)
      end)
    end

    assert :counters.get(counter, 1) == 1
  end

  test "joins an outer transaction without retrying", %{workspace: ws, admin: admin} do
    scope = workspace_scope_fixture(admin, ws)

    assert {:ok, {:ok, :inner}} =
             Helmsman.Tx.run(fn ->
               {:ok,
                Workspaces.write_transaction(scope, :update_workspace, fn _ -> {:ok, :inner} end)}
             end)
  end

  test "an unchanged membership still authorizes after reload",
       %{workspace: ws, admin: admin} do
    scope = workspace_scope_fixture(admin, ws)
    assert Repo.get_by!(Membership, workspace_id: ws.id, user_id: admin.id).role == :admin

    assert {:ok, nil} =
             Workspaces.write_transaction(scope, :update_workspace, fn _ -> {:ok, nil} end)
  end
end
