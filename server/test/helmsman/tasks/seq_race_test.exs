defmodule Helmsman.Tasks.SeqRaceTest do
  # Every creation runs on a connection of its own outside the sandbox.
  use ExUnit.Case, async: false

  import Helmsman.AccountsFixtures
  import Helmsman.ProjectsFixtures
  import Helmsman.WorkspacesFixtures

  alias Helmsman.CommittedData
  alias Helmsman.Projects
  alias Helmsman.Tasks

  @creators 20

  setup do
    tag = System.unique_integer([:positive])

    {owner, scope} =
      CommittedData.unboxed(fn ->
        owner = user_fixture(%{email: "owner-#{tag}@seq-race.test"})
        workspace = workspace_fixture(owner)
        scope = workspace_scope_fixture(owner, workspace)
        project_fixture(scope, key: "BOS")
        {owner, scope}
      end)

    on_exit(fn -> CommittedData.delete_user_data!([owner.id]) end)
    %{scope: scope}
  end

  test "20 simultaneous creations get BOS-1 to BOS-20 exactly once", %{scope: scope} do
    parent = self()

    tasks =
      for i <- 1..@creators do
        Task.async(fn ->
          CommittedData.unboxed(fn ->
            send(parent, {:ready, self()})

            receive do
              :go -> Tasks.create(scope, "BOS", %{title: "Task #{i}"})
            end
          end)
        end)
      end

    for _ <- 1..@creators, do: assert_receive({:ready, _pid}, 5_000)
    # Barrier: all start together.
    Enum.each(tasks, &send(&1.pid, :go))

    results = Task.await_many(tasks, 30_000)
    idents = for {:ok, task} <- results, do: task.ident

    assert Enum.sort(idents) == Enum.sort(for n <- 1..@creators, do: "BOS-#{n}")

    assert {:ok, %{task_seq: @creators}} =
             CommittedData.unboxed(fn -> Projects.get(scope, "BOS") end)
  end
end
