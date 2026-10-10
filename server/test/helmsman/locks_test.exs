defmodule Helmsman.LocksTest do
  # Uses separate connections outside the sandbox.
  use ExUnit.Case, async: false

  import Bitwise

  alias Helmsman.CommittedData
  alias Helmsman.Locks
  alias Helmsman.Repo

  describe "key/2" do
    test "puts the type in the bits above 48" do
      assert Locks.key(:global, 1) == 1
      assert Locks.key(:maint, 7) == (1 <<< 48) + 7
      assert Locks.key(:graph, 7) == (2 <<< 48) + 7
      assert Locks.key(:task, 0) == 3 <<< 48
      assert Locks.key(:daemon, (1 <<< 48) - 1) == (5 <<< 48) - 1
    end

    test "raises for ids outside 0..2^48-1" do
      assert_raise ArgumentError, fn -> Locks.key(:maint, 1 <<< 48) end
      assert_raise ArgumentError, fn -> Locks.key(:maint, -1) end
    end
  end

  test "locks must be taken inside a transaction" do
    CommittedData.unboxed(fn ->
      assert_raise RuntimeError, ~r/inside a transaction/, fn -> Locks.maint_shared!(1) end
    end)
  end

  test "all lock functions run inside a transaction" do
    CommittedData.unboxed(fn ->
      Repo.transact(fn ->
        assert :ok = Locks.registration!()
        assert :ok = Locks.maint_shared!(42)
        assert :ok = Locks.graph!(42)
        assert Locks.try_task(42)
        assert Locks.try_daemon(42)
        {:ok, nil}
      end)
    end)
  end

  test "an exclusive maintenance lock blocks try_maint_shared until released" do
    parent = self()
    ws = System.unique_integer([:positive])

    holder = Task.async(fn -> CommittedData.unboxed(fn -> hold_exclusive(parent, ws) end) end)

    assert_receive :held, 5_000
    refute try_shared(ws)

    send(holder.pid, :release)
    Task.await(holder)

    assert try_shared(ws)
  end

  defp hold_exclusive(parent, ws) do
    Repo.transact(fn ->
      Locks.maint_exclusive!(ws)
      send(parent, :held)

      receive do
        :release -> {:ok, nil}
      end
    end)
  end

  defp try_shared(ws) do
    Task.async(fn -> CommittedData.unboxed(fn -> try_shared_in_transaction(ws) end) end)
    |> Task.await()
  end

  defp try_shared_in_transaction(ws) do
    {:ok, acquired?} = Repo.transact(fn -> {:ok, Locks.try_maint_shared(ws)} end)
    acquired?
  end
end
