defmodule Helmsman.TxEventsTest do
  # The last test commits on its own connections outside the sandbox.
  use Helmsman.DataCase, async: false

  alias Helmsman.CommittedData
  alias Helmsman.Events
  alias Helmsman.Tx

  @topic "tx-events-test"

  setup do
    Events.subscribe(@topic)
    :ok
  end

  defp insert_workspace(slug) do
    now = DateTime.utc_now(:second)

    {1, [%{id: id}]} =
      Repo.insert_all(
        "workspaces",
        [%{slug: slug, name: slug, inserted_at: now, updated_at: now}],
        returning: [:id]
      )

    id
  end

  describe "Tx.after_commit/1" do
    test "runs callbacks only after the outermost commit, in order" do
      parent = self()

      assert {:ok, :done} =
               Tx.run(fn ->
                 Tx.after_commit(fn -> send(parent, {:cb, 1, Repo.in_transaction?()}) end)
                 Tx.after_commit(fn -> send(parent, {:cb, 2, Repo.in_transaction?()}) end)
                 refute_received {:cb, _, _}
                 {:ok, :done}
               end)

      assert_received {:cb, 1, false}
      assert_received {:cb, 2, false}
    end

    test "does not run callbacks when the transaction returns an error" do
      parent = self()

      assert {:error, :nope} =
               Tx.run(fn ->
                 Tx.after_commit(fn -> send(parent, :cb) end)
                 {:error, :nope}
               end)

      refute_received :cb
    end

    test "does not run callbacks when the transaction raises" do
      parent = self()

      assert_raise RuntimeError, "boom", fn ->
        Tx.run(fn ->
          Tx.after_commit(fn -> send(parent, :cb) end)
          raise "boom"
        end)
      end

      refute_received :cb
      # The queue is gone: a later transaction starts clean.
      assert {:ok, nil} = Tx.run(fn -> {:ok, nil} end)
      refute_received :cb
    end

    test "raises outside Tx.run/1, including in a plain Repo transaction" do
      assert_raise RuntimeError, ~r/Tx.run/, fn -> Tx.after_commit(fn -> :ok end) end

      assert_raise RuntimeError, ~r/Tx.run/, fn ->
        Repo.transact(fn -> Tx.after_commit(fn -> :ok end) end)
      end
    end
  end

  describe "Tx.run/2 retries" do
    defp deadlock do
      %Postgrex.Error{
        postgres: %{code: :deadlock_detected, severity: "ERROR", pg_code: "40P01", message: "x"}
      }
    end

    test "without :retry a deadlock is raised" do
      assert_raise Postgrex.Error, fn -> Tx.run(fn -> raise deadlock() end) end
    end

    test "with :retry the transaction runs again, and then returns the error" do
      counter = :counters.new(1, [])

      assert {:error, :deadlock_detected} =
               Tx.run(
                 fn ->
                   :counters.add(counter, 1, 1)
                   raise deadlock()
                 end,
                 retry: 1
               )

      assert :counters.get(counter, 1) == 2
    end

    test "a failing callback is logged and the others still run" do
      parent = self()

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:ok, :done} =
                   Tx.run(fn ->
                     Tx.after_commit(fn -> raise "side effect failed" end)
                     Tx.after_commit(fn -> send(parent, :second) end)
                     {:ok, :done}
                   end)
        end)

      assert log =~ "side effect failed"
      assert_received :second
    end
  end

  describe "Events.broadcast/2" do
    test "delivers outside a transaction" do
      assert :ok = Events.broadcast(@topic, :hello)
      assert_received :hello
    end

    test "raises inside a transaction" do
      assert_raise RuntimeError, ~r/after_commit/, fn ->
        Repo.transact(fn -> Events.broadcast(@topic, :hello) end)
      end

      assert_raise RuntimeError, ~r/after_commit/, fn ->
        Tx.run(fn -> Events.broadcast(@topic, :hello) end)
      end

      refute_received :hello
    end
  end

  describe "nested Tx.run/1" do
    test "inner events are dropped when the outer transaction rolls back" do
      assert {:error, :later_step_failed} =
               Tx.run(fn ->
                 {:ok, _} =
                   Tx.run(fn ->
                     id = insert_workspace("nested")
                     Events.after_commit(@topic, {:inner, id})
                     {:ok, id}
                   end)

                 {:error, :later_step_failed}
               end)

      refute_received {:inner, _}
      refute Repo.exists?(from(w in "workspaces", where: w.slug == "nested"))
    end

    test "inner and outer events are sent in order after the outer commit" do
      assert {:ok, _} =
               Tx.run(fn ->
                 Events.after_commit(@topic, :first)

                 {:ok, _} =
                   Tx.run(fn ->
                     Events.after_commit(@topic, :second)
                     {:ok, nil}
                   end)

                 refute_received _
                 Events.after_commit(@topic, :third)
                 {:ok, nil}
               end)

      assert {:messages, [:first, :second, :third]} = Process.info(self(), :messages)
    end

    test "an inner error rolls back the outer transaction" do
      assert {:error, :rollback} =
               Tx.run(fn ->
                 Events.after_commit(@topic, :outer)
                 {:error, :inner} = Tx.run(fn -> {:error, :inner} end)
                 {:ok, :ignored}
               end)

      refute_received :outer
    end
  end

  test "a subscriber reading on its own connection sees the committed change" do
    parent = self()
    slug = "committed-#{System.unique_integer([:positive])}"

    subscriber =
      Task.async(fn ->
        CommittedData.unboxed(fn ->
          Events.subscribe(@topic)
          send(parent, :subscribed)

          receive do
            {:created, id} ->
              Repo.one(from(w in "workspaces", where: w.id == ^id, select: w.slug))
          end
        end)
      end)

    assert_receive :subscribed

    on_exit(fn ->
      CommittedData.unboxed(fn ->
        Repo.delete_all(from(w in "workspaces", where: w.slug == ^slug))
      end)
    end)

    CommittedData.unboxed(fn ->
      Tx.run(fn ->
        id = insert_workspace(slug)
        Events.after_commit(@topic, {:created, id})
        {:ok, id}
      end)
    end)

    assert Task.await(subscriber) == slug
  end
end
