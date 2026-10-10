defmodule Helmsman.Members.LastOwnerRaceTest do
  # Each demotion runs on a connection of its own outside the sandbox and
  # holds its transaction open until the test lets it commit.
  use ExUnit.Case, async: false

  import Helmsman.AccountsFixtures
  import Helmsman.WorkspacesFixtures

  alias Helmsman.CommittedData
  alias Helmsman.Members
  alias Helmsman.Tx
  alias Helmsman.Workspaces

  setup do
    tag = System.unique_integer([:positive])

    {owners, workspace} =
      CommittedData.unboxed(fn ->
        alice = user_fixture(%{email: "alice-#{tag}@owner-race.test"})
        bob = user_fixture(%{email: "bob-#{tag}@owner-race.test"})
        workspace = workspace_fixture(alice)
        member_fixture(workspace, bob, :owner)
        {[alice, bob], workspace}
      end)

    on_exit(fn ->
      CommittedData.delete_user_data!(Enum.map(owners, & &1.id), [workspace.id])
    end)

    scopes =
      CommittedData.unboxed(fn ->
        for owner <- owners do
          scope = workspace_scope_fixture(owner, workspace)
          {scope, Workspaces.get_membership(workspace.id, owner.id)}
        end
      end)

    %{scopes: scopes, workspace: workspace}
  end

  test "two owners demoting themselves at once: exactly one succeeds",
       %{scopes: scopes, workspace: ws} do
    parent = self()

    tasks =
      for {scope, own} <- scopes do
        Task.async(fn -> CommittedData.unboxed(fn -> demote_and_hold(parent, scope, own) end) end)
      end

    backends =
      Map.new(tasks, fn _ ->
        assert_receive {:ready, pid, backend}, 5_000
        {pid, backend}
      end)

    # Barrier: both start together.
    Enum.each(tasks, &send(&1.pid, :go))

    assert_receive {:done, first, _result}, 5_000
    [second] = Map.keys(backends) -- [first]

    # Commit the first only once the other has read the owners: it is
    # either waiting for the first one's row locks or, without them, done
    # as well (and then both demotions would commit).
    assert wait_for_lock_or_done(second, backends[second]) in [:blocked, :done]

    send(first, :commit)
    assert_receive {:done, ^second, _result}, 5_000
    send(second, :commit)

    results = Task.await_many(tasks, 10_000)
    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.count(results, &(&1 == {:error, :last_owner})) == 1

    roles =
      CommittedData.unboxed(fn ->
        for {scope, _} <- scopes, do: Workspaces.get_membership(ws.id, scope.user.id).role
      end)

    assert Enum.sort(roles) == [:admin, :owner]
  end

  defp demote_and_hold(parent, scope, own) do
    Tx.run(fn ->
      send(parent, {:ready, self(), CommittedData.backend_pid()})

      receive do
        :go -> :ok
      end

      result = Members.change_role(scope, own.id, :admin)
      send(parent, {:done, self(), result})

      receive do
        :commit -> result
      end
    end)
  end

  defp wait_for_lock_or_done(pid, backend, attempts \\ 500) do
    receive do
      {:done, ^pid, _result} = done ->
        send(self(), done)
        :done
    after
      0 ->
        cond do
          CommittedData.lock_waiting?(backend) ->
            :blocked

          attempts == 0 ->
            :timeout

          true ->
            Process.sleep(10)
            wait_for_lock_or_done(pid, backend, attempts - 1)
        end
    end
  end
end
