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

  alias Helmsman.{CommittedData, Dispatch, Feedback, Repo, Runs, Tasks, Tx}
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
        step = task_fixture(ctx.alice_scope, ctx.project.key, %{epic: epic.ident})
        loose = task_fixture(ctx.alice_scope, ctx.project.key)
        Tx.run(fn -> {:ok, Runs.cancel_pending(from(r in Run), :obsolete)} end)
        Repo.delete_all(from(r in Run, where: r.task_id == ^epic.id))

        Map.merge(ctx, %{
          docs: docs,
          docs_actor: agent_actor(ctx.workspace, "docs-team"),
          epic: epic,
          step: step,
          loose: loose
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

  # Writes `attrs` to the task `ident` with the normal `Tasks.update/4` on
  # a connection of its own; returns the waiting process and the backend
  # PID of that connection.
  defp update_async(ctx, ident, attrs) do
    parent = self()

    task =
      Task.async(fn ->
        CommittedData.unboxed(fn ->
          send(parent, {:backend, self(), Repo.query!("SELECT pg_backend_pid()").rows})
          Tasks.update(ctx.alice_scope, ident, attrs)
        end)
      end)

    assert_receive {:backend, _pid, [[backend]]}, 10_000
    {task, backend}
  end

  # Waits, on a connection of its own, until the backend `backend` waits
  # for an advisory lock (the graph lock the write under test holds).
  defp await_lock_wait(backend, deadline \\ System.monotonic_time(:millisecond) + 10_000) do
    waiting =
      Task.async(fn ->
        CommittedData.unboxed(fn ->
          Repo.exists?(
            from(l in fragment("SELECT pid, locktype, granted FROM pg_locks"),
              where: l.pid == ^backend and l.locktype == "advisory" and not l.granted
            )
          )
        end)
      end)
      |> Task.await()

    cond do
      waiting ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        flunk("the concurrent update never waited for the graph lock")

      true ->
        Process.sleep(20)
        await_lock_wait(backend, deadline)
    end
  end

  defp runs_of(task) do
    CommittedData.unboxed(fn ->
      Repo.all(
        from(r in Run, where: r.task_id == ^task.id and r.status == :queued, select: r.squad_id)
      )
    end)
  end

  defp epic_assignee(ctx),
    do: CommittedData.unboxed(fn -> Repo.get!(TaskRow, ctx.epic.id).assignee_id end)

  # The epic's owner is cleared while the write holds what it read under
  # the task lock: the update waits for it, then applies.
  defp clear_epic_after_candidate(ctx) do
    fn
      :leader_candidate ->
        unless Process.get(:race_update) do
          {task, backend} = update_async(ctx, ctx.epic.ident, %{assignee: ""})
          Process.put(:race_update, task)
          await_lock_wait(backend)
        end

      _other ->
        :ok
    end
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

  describe "on a step, the epic's owner" do
    test "a mention: changed after the candidate is read, waits for the run as the squad", ctx do
      assert {:ok, _} =
               CommittedData.unboxed(fn ->
                 with_hook(clear_epic_after_candidate(ctx), fn ->
                   Feedback.add(ctx.alice_scope, ctx.step.ident, %{content: "@keel/lead help"})
                 end)
               end)

      assert {:ok, _} = Task.await(Process.delete(:race_update), 10_000)
      assert runs_of(ctx.step) == [ctx.squad.id]
      assert epic_assignee(ctx) == nil
    end

    test "a manual run: changed after the candidate is read, waits for the run as the squad",
         ctx do
      assert {:ok, _} =
               CommittedData.unboxed(fn ->
                 with_hook(clear_epic_after_candidate(ctx), fn ->
                   Dispatch.run_agent(ctx.alice_scope, "keel/lead", ctx.step.ident, nil)
                 end)
               end)

      assert {:ok, _} = Task.await(Process.delete(:race_update), 10_000)
      assert runs_of(ctx.step) == [ctx.squad.id]
      assert epic_assignee(ctx) == nil
    end

    test "a mention: changed before the locks, the leader runs alone", ctx do
      hook = fn
        {:dispatch_targets_guessed, 1} ->
          {:ok, _} =
            ctx |> update_async(ctx.epic.ident, %{assignee: ""}) |> elem(0) |> Task.await()

        _other ->
          :ok
      end

      assert {:ok, _} =
               CommittedData.unboxed(fn ->
                 with_hook(hook, fn ->
                   Feedback.add(ctx.alice_scope, ctx.step.ident, %{content: "@keel/lead help"})
                 end)
               end)

      assert runs_of(ctx.step) == [nil]
    end

    test "a manual run: changed before the locks, the leader runs alone", ctx do
      hook = fn
        {:run_agent, 1} ->
          {:ok, _} =
            ctx |> update_async(ctx.epic.ident, %{assignee: ""}) |> elem(0) |> Task.await()

        _other ->
          :ok
      end

      assert {:ok, _} =
               CommittedData.unboxed(fn ->
                 with_hook(hook, fn ->
                   Dispatch.run_agent(ctx.alice_scope, "keel/lead", ctx.step.ident, nil)
                 end)
               end)

      assert runs_of(ctx.step) == [nil]
    end

    test "a mention: the task becomes a step after the guess, the round is taken with the graph lock",
         ctx do
      parent = self()

      hook = fn
        {:dispatch_targets, 1} ->
          {:ok, _} =
            ctx
            |> update_async(ctx.loose.ident, %{epic: ctx.epic.ident})
            |> elem(0)
            |> Task.await()

        {:dispatch_targets_graph, round, graph?} ->
          send(parent, {:round, round, graph?})

        _other ->
          :ok
      end

      assert {:ok, _} =
               CommittedData.unboxed(fn ->
                 with_hook(hook, fn ->
                   Feedback.add(ctx.alice_scope, ctx.loose.ident, %{content: "@keel/lead help"})
                 end)
               end)

      assert_received {:round, 2, true}
      assert runs_of(ctx.loose) == [ctx.squad.id]
    end

    test "a manual run: the task becomes a step after the guess, the round is taken with the graph lock",
         ctx do
      parent = self()

      hook = fn
        {:run_agent_graph, 1, false} ->
          {:ok, _} =
            ctx
            |> update_async(ctx.loose.ident, %{epic: ctx.epic.ident})
            |> elem(0)
            |> Task.await()

        {:run_agent_graph, round, graph?} ->
          send(parent, {:round, round, graph?})

        _other ->
          :ok
      end

      assert {:ok, _} =
               CommittedData.unboxed(fn ->
                 with_hook(hook, fn ->
                   Dispatch.run_agent(ctx.alice_scope, "keel/lead", ctx.loose.ident, nil)
                 end)
               end)

      assert_received {:round, 2, true}
      assert runs_of(ctx.loose) == [ctx.squad.id]
    end
  end
end
