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
end
