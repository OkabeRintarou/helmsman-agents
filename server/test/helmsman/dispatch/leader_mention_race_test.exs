defmodule Helmsman.Dispatch.LeaderMentionRaceTest do
  # improve-squad-leader-orchestration 3.1 / 3.2: the squad a mentioned or
  # started leader runs as is decided again under the task lock (decision
  # 14). The concurrent change commits on a connection of its own, so that
  # rolling back a round does not undo it.
  use ExUnit.Case, async: false

  import Ecto.Query
  import Helmsman.RunsFixtures, only: [agent_actor: 2]
  import Helmsman.ProjectsFixtures
  import Helmsman.SquadsFixtures

  alias Helmsman.{CommittedData, Dispatch, Feedback, Repo, Tasks}
  alias Helmsman.Runs.Run
  alias Helmsman.Tasks.Task, as: TaskRow

  @moduletag timeout: 60_000

  setup do
    ctx =
      CommittedData.unboxed(fn ->
        ctx = squads_fixture()
        docs = squad_fixture(ctx.alice_scope, %{name: "docs-team", leader: "keel/lead"})
        epic = task_fixture(ctx.alice_scope, ctx.project.key, %{kind: "epic"})
        {:ok, _} = Tasks.update(ctx.alice_scope, epic.ident, %{assignee: "web-team"})
        Repo.delete_all(from(r in Run, where: r.task_id == ^epic.id))

        Map.merge(ctx, %{
          docs: docs,
          docs_actor: agent_actor(ctx.workspace, "docs-team"),
          epic: epic
        })
      end)

    on_exit(fn -> CommittedData.delete_user_data!([ctx.alice.id, ctx.bob.id, ctx.carol.id]) end)
    ctx
  end

  # Gives the epic to docs-team on a connection of its own, and commits.
  defp move_to_docs!(ctx) do
    Task.async(fn ->
      CommittedData.unboxed(fn ->
        Repo.update_all(from(t in TaskRow, where: t.id == ^ctx.epic.id),
          set: [assignee_id: ctx.docs_actor.id]
        )
      end)
    end)
    |> Task.await()
  end

  defp with_hook(hook, fun) do
    Process.put(:helmsman_test_hook, hook)

    try do
      fun.()
    after
      Process.delete(:helmsman_test_hook)
    end
  end

  defp squad_of_run(ctx) do
    CommittedData.unboxed(fn ->
      Repo.all(from(r in Run, where: r.task_id == ^ctx.epic.id, select: r.squad_id))
    end)
  end

  test "a mention: the epic moves to another squad of the leader before the task lock", ctx do
    hook = fn
      {:dispatch_targets, 1} -> move_to_docs!(ctx)
      _other -> :ok
    end

    assert {:ok, _} =
             CommittedData.unboxed(fn ->
               with_hook(hook, fn ->
                 Feedback.add(ctx.alice_scope, ctx.epic.ident, %{content: "@keel/lead ?"})
               end)
             end)

    assert squad_of_run(ctx) == [ctx.docs.id]
  end

  test "a manual run: the epic moves to another squad of the leader before the task lock",
       ctx do
    hook = fn
      {:run_agent, 1} -> move_to_docs!(ctx)
      _other -> :ok
    end

    assert {:ok, _} =
             CommittedData.unboxed(fn ->
               with_hook(hook, fn ->
                 Dispatch.run_agent(ctx.alice_scope, "keel/lead", ctx.epic.ident, nil)
               end)
             end)

    assert squad_of_run(ctx) == [ctx.docs.id]
  end
end
