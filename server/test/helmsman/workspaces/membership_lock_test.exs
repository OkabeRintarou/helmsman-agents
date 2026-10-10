defmodule Helmsman.Workspaces.MembershipLockTest do
  # Checks row locks from a second connection, outside the sandbox.
  use ExUnit.Case, async: false

  import Helmsman.AccountsFixtures
  import Helmsman.WorkspacesFixtures

  alias Helmsman.CommittedData
  alias Helmsman.Repo
  alias Helmsman.Workspaces

  setup do
    {user, workspace} =
      CommittedData.unboxed(fn ->
        user = user_fixture(%{email: "lock-#{System.unique_integer([:positive])}@lock.test"})
        {user, workspace_fixture(user)}
      end)

    on_exit(fn -> CommittedData.delete_user_data!([user.id]) end)

    %{user: user, workspace: workspace}
  end

  for {opt, locked?} <- [{[], true}, {[membership_lock: :none], false}] do
    test "opts #{inspect(opt)} → membership row share-locked: #{locked?}",
         %{user: user, workspace: ws} do
      assert membership_locked_during_write?(user, ws, unquote(opt)) == unquote(locked?)
    end
  end

  # Holds a write transaction open and asks another connection for the
  # membership row FOR UPDATE NOWAIT.
  defp membership_locked_during_write?(user, ws, opts) do
    parent = self()

    writer =
      Task.async(fn ->
        CommittedData.unboxed(fn -> hold_write(parent, user, ws, opts) end)
      end)

    assert_receive :in_write, 5_000

    locked? =
      Task.await(Task.async(fn -> CommittedData.unboxed(fn -> try_lock(ws, user) end) end))

    send(writer.pid, :release)
    assert {:ok, :done} = Task.await(writer)
    locked?
  end

  defp hold_write(parent, user, ws, opts) do
    scope = workspace_scope_fixture(user, ws)

    Workspaces.write_transaction(
      scope,
      :view_workspace,
      nil,
      fn _ ->
        send(parent, :in_write)

        receive do
          :release -> {:ok, :done}
        end
      end,
      opts
    )
  end

  defp try_lock(ws, user) do
    Repo.transact(fn ->
      Repo.query(
        "SELECT id FROM memberships WHERE workspace_id = $1 AND user_id = $2 FOR UPDATE NOWAIT",
        [ws.id, user.id]
      )
    end)
    |> case do
      {:ok, _} -> false
      {:error, %Postgrex.Error{postgres: %{code: :lock_not_available}}} -> true
    end
  end
end
