defmodule Helmsman.Feedback.RaceTest do
  # Every write runs on a connection of its own outside the sandbox.
  use ExUnit.Case, async: false

  import Helmsman.AccountsFixtures
  import Helmsman.ProjectsFixtures
  import Helmsman.WorkspacesFixtures

  alias Helmsman.CommittedData
  alias Helmsman.Feedback
  alias Helmsman.Repo
  alias Helmsman.Tasks.Task

  @writers 10

  setup do
    tag = System.unique_integer([:positive])

    {owner, scope, task} =
      CommittedData.unboxed(fn ->
        owner = user_fixture(%{email: "owner-#{tag}@feedback-race.test"})
        workspace = workspace_fixture(owner)
        scope = workspace_scope_fixture(owner, workspace)
        project_fixture(scope, key: "BOS")
        {owner, scope, task_fixture(scope, "BOS")}
      end)

    on_exit(fn -> CommittedData.delete_user_data!([owner.id]) end)
    %{scope: scope, task: task}
  end

  # Runs `fun` in `n` processes on their own connections, all released at
  # once, and returns their results.
  defp simultaneously(n, fun) do
    parent = self()

    tasks =
      for i <- 1..n do
        Elixir.Task.async(fn -> unboxed_on_go(parent, fun, i) end)
      end

    for _ <- 1..n, do: assert_receive({:ready, _pid}, 5_000)
    Enum.each(tasks, &send(&1.pid, :go))
    Elixir.Task.await_many(tasks, 30_000)
  end

  defp unboxed_on_go(parent, fun, i) do
    CommittedData.unboxed(fn ->
      send(parent, {:ready, self()})

      receive do
        :go -> fun.(i)
      end
    end)
  end

  test "10 simultaneous additions get #1 to #10 exactly once", %{scope: scope, task: task} do
    results =
      simultaneously(@writers, fn i ->
        Feedback.add(scope, task.ident, %{content: "Feedback #{i}"})
      end)

    seqs = for {:ok, entry} <- results, do: entry.seq
    assert Enum.sort(seqs) == Enum.to_list(1..@writers)

    assert %Task{feedback_seq: @writers, feedback_count: @writers} =
             CommittedData.unboxed(fn -> Repo.get!(Task, task.id) end)
  end

  test "reply racing its target revision preserves root and resolves the committed version", %{
    scope: scope,
    task: task
  } do
    {:ok, root} =
      CommittedData.unboxed(fn -> Feedback.add(scope, task.ident, %{content: "Root"}) end)

    id = Feedback.view(root).id

    results =
      simultaneously(2, fn
        1 -> Feedback.add(scope, task.ident, %{content: "Reply", reply_to: id})
        2 -> Feedback.revise(scope, id, %{content: "Current"})
      end)

    assert Enum.all?(results, &match?({:ok, _}, &1))
    {:ok, reply} = Enum.find(results, fn {:ok, entry} -> entry.reply_to_seq != nil end)
    {:ok, loaded} = CommittedData.unboxed(fn -> Feedback.get(scope, Feedback.view(reply).id) end)
    assert loaded.reply_to_seq == root.seq
    assert loaded.reply_root_seq == root.thread_seq
    assert loaded.target.summary == "Current"
    assert loaded.target.status == "superseded"

    assert %Task{feedback_seq: 3, feedback_count: 2} =
             CommittedData.unboxed(fn -> Repo.get!(Task, task.id) end)
  end

  test "two simultaneous revisions: one wins, the other is superseded",
       %{scope: scope, task: task} do
    {:ok, entry} =
      CommittedData.unboxed(fn -> Feedback.add(scope, task.ident, %{content: "v1"}) end)

    id = Feedback.view(entry).id

    results =
      simultaneously(2, fn i -> Feedback.revise(scope, id, %{content: "v#{i + 1}"}) end)

    {oks, errors} = Enum.split_with(results, &match?({:ok, _}, &1))
    assert [{:ok, winner}] = oks
    assert errors == [{:error, {:superseded, "BOS-1#2"}}]
    assert winner.seq == 2

    assert %Task{feedback_seq: 2, feedback_count: 1} =
             CommittedData.unboxed(fn -> Repo.get!(Task, task.id) end)
  end
end
