defmodule Helmsman.Tasks.TransitionRaceTest do
  # Each transition runs on a connection of its own outside the sandbox.
  use ExUnit.Case, async: false

  import Helmsman.AccountsFixtures
  import Helmsman.ProjectsFixtures
  import Helmsman.WorkspacesFixtures

  alias Helmsman.CommittedData
  alias Helmsman.Repo
  alias Helmsman.Tasks

  setup do
    tag = System.unique_integer([:positive])

    {owner, scope, task} =
      CommittedData.unboxed(fn ->
        owner = user_fixture(%{email: "owner-#{tag}@transition-race.test"})
        workspace = workspace_fixture(owner)
        scope = workspace_scope_fixture(owner, workspace)
        project_fixture(scope, key: "BOS")
        task = task_fixture(scope, "BOS")
        {:ok, _} = Tasks.transition(scope, task.ident, "in_progress")
        {owner, scope, task}
      end)

    on_exit(fn -> CommittedData.delete_user_data!([owner.id]) end)
    %{scope: scope, task: task}
  end

  test "done and cancelled at the same time: exactly one wins", %{scope: scope, task: task} do
    parent = self()

    racers =
      for to <- ["done", "cancelled"] do
        Task.async(fn ->
          CommittedData.unboxed(fn ->
            send(parent, {:ready, self()})

            receive do
              :go -> Tasks.transition(scope, task.ident, to)
            end
          end)
        end)
      end

    for _ <- racers, do: assert_receive({:ready, _pid}, 5_000)
    # Barrier: both start together.
    Enum.each(racers, &send(&1.pid, :go))

    results = Task.await_many(racers, 30_000)

    assert [{:ok, %{status: winner}}] = for({:ok, _} = ok <- results, do: ok)

    assert [{:error, {:invalid_transition, from, _to, _allowed}}] =
             for({:error, _} = error <- results, do: error)

    assert Atom.to_string(from) == winner

    %{rows: [[count]]} =
      CommittedData.unboxed(fn ->
        Repo.query!("SELECT count(*) FROM task_events WHERE task_id = $1", [task.id])
      end)

    # Creation, start and the winner.
    assert count == 3
  end

  test "expected_from is compared under the task lock (domain-decision-3)",
       %{scope: scope, task: task} do
    parent = self()
    tests = %{command: "mix test", passed: true, summary: "1 test, 0 failures"}
    CommittedData.unboxed(fn -> {:ok, _} = Tasks.transition(scope, task.ident, "done") end)

    verifier =
      start(parent, fn ->
        Process.put(:helmsman_test_hook, fn
          :reason_inserted ->
            send(parent, {:held, self()})

            receive do
              :continue -> :ok
            end

          _other ->
            :ok
        end)

        Tasks.transition(scope, task.ident, "verified", tests: tests)
      end)

    assert_receive {:backend, verifier_pid, _backend}, 5_000
    assert_receive {:held, ^verifier_pid}, 5_000

    restarter =
      start(parent, fn ->
        Tasks.transition(scope, task.ident, "in_progress", expected_from: :done)
      end)

    assert_receive {:backend, restarter_pid, backend}, 5_000
    assert restarter_pid == restarter.pid
    CommittedData.await_lock_wait(backend)

    send(verifier.pid, :continue)
    assert {:ok, %{status: "verified"}} = Task.await(verifier, 10_000)
    assert Task.await(restarter, 10_000) == {:error, {:status_changed, :verified}}

    CommittedData.unboxed(fn ->
      assert {:ok, %{status: :verified}} = Tasks.get(scope, task.ident)

      # Creation, start, done and the verification.
      assert %{rows: [[4]]} =
               Repo.query!("SELECT count(*) FROM task_events WHERE task_id = $1", [task.id])
    end)
  end

  defp start(parent, fun) do
    Task.async(fn ->
      CommittedData.unboxed(fn ->
        send(parent, {:backend, self(), CommittedData.backend_pid()})
        fun.()
      end)
    end)
  end
end
