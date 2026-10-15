defmodule Helmsman.Squads.OrchestrationLockingTest do
  # improve-squad-leader-orchestration 1.6: squad-orchestration 「编排写入的
  # 加锁」 (decision 8). The concurrent writes commit on connections of
  # their own.
  use ExUnit.Case, async: false

  import Ecto.Query
  import Helmsman.AgentsFixtures
  import Helmsman.OrchestrationFixtures
  import Helmsman.RunsFixtures

  alias Helmsman.{Agents, CommittedData, Feedback, LockHarness, Repo, Squads, Tasks}
  alias Helmsman.Runs.Run
  alias Helmsman.Tasks.Task, as: TaskRow

  @moduletag timeout: 60_000

  setup do
    ctx =
      CommittedData.unboxed(fn ->
        ctx = orchestration_fixture()

        for name <- ~w(keel/x1 keel/x2 keel/x3) do
          managed_agent_fixture(ctx.alice_scope, %{
            name: name,
            runtime_id: ctx.runtime_id,
            access: "workspace"
          })
        end

        {scope, run} = leader_run(ctx, ctx.lead, ctx.s1)
        Map.merge(ctx, %{scope: scope, run: run})
      end)

    on_exit(fn -> CommittedData.delete_user_data!([ctx.alice.id, ctx.bob.id, ctx.carol.id]) end)
    ctx
  end

  defp unboxed(fun), do: CommittedData.unboxed(fun)
  defp commit!(fun), do: Task.async(fn -> unboxed(fun) end) |> Task.await(10_000)

  defp with_hook(hook, fun) do
    Process.put(:helmsman_test_hook, hook)

    try do
      fun.()
    after
      Process.delete(:helmsman_test_hook)
    end
  end

  # Sets the assignee directly on a connection of its own: what a
  # concurrent reassignment leaves.
  defp reassign!(ctx, task, name) do
    commit!(fn ->
      id = agent_actor(ctx.workspace, name).id
      Repo.update_all(from(t in TaskRow, where: t.id == ^task.id), set: [assignee_id: id])
    end)
  end

  defp runs(task),
    do:
      unboxed(fn ->
        Repo.all(from(r in Run, where: r.task_id == ^task.id and r.status == :queued))
      end)

  describe "start_task: the assignee guessed, locked, checked" do
    test "reassigned between the guess and the task lock: the new assignee", ctx do
      hook = fn
        {:dispatch_targets, 1} -> reassign!(ctx, ctx.s2, "keel/qa")
        _other -> :ok
      end

      assert {:ok, %{result: :queued, assignee: "keel/qa"}} =
               unboxed(fn ->
                 with_hook(hook, fn -> Squads.start_task(ctx.scope, ctx.s2.ident) end)
               end)

      assert [%Run{agent_id: qa}] = runs(ctx.s2)
      assert qa == ctx.qa.id
    end

    test "changing every round: busy after 3, nothing written", ctx do
      names = %{1 => "keel/x1", 2 => "keel/x2", 3 => "keel/x3"}

      hook = fn
        {:dispatch_targets, n} -> reassign!(ctx, ctx.s2, names[n])
        _other -> :ok
      end

      assert {:error, :busy} =
               unboxed(fn ->
                 with_hook(hook, fn -> Squads.start_task(ctx.scope, ctx.s2.ident) end)
               end)

      assert runs(ctx.s2) == []
    end
  end

  describe "an orchestrated reassignment and a concurrent change" do
    defp assign(ctx),
      do: fn -> Tasks.update(ctx.scope, ctx.s3.ident, %{assignee: "keel/qa", start: false}) end

    defp orchestration_first(ctx, other) do
      a = LockHarness.start(assign(ctx), pause: :commit)
      LockHarness.await_paused(a)
      b = LockHarness.start(other)
      LockHarness.await_blocked(b)
      LockHarness.continue(a)
      {LockHarness.result(a), LockHarness.result(b)}
    end

    defp other_first(ctx, other) do
      b = LockHarness.start(other, pause: :commit)
      LockHarness.await_paused(b)
      a = LockHarness.start(assign(ctx))
      LockHarness.await_blocked(a)
      LockHarness.continue(b)
      {LockHarness.result(a), LockHarness.result(b)}
    end

    test "with a change of leader", ctx do
      change = fn -> Squads.update(ctx.alice_scope, "web-team", %{leader: "keel/dev"}) end
      assert {{:ok, _}, {:ok, _}} = orchestration_first(ctx, change)

      unboxed(fn ->
        {:ok, _} = Squads.update(ctx.alice_scope, "web-team", %{leader: "keel/lead"})
      end)

      unboxed(fn -> {:ok, _} = Tasks.update(ctx.alice_scope, ctx.s3.ident, %{assignee: ""}) end)

      assert {{:error, {:orchestration, :not_leader, "web-team"}}, {:ok, _}} =
               other_first(ctx, change)
    end

    test "with the step detached", ctx do
      detach = fn -> Tasks.update(ctx.alice_scope, ctx.s3.ident, %{epic: ""}) end
      assert {{:error, {:orchestration, :outside, _, _}}, {:ok, _}} = other_first(ctx, detach)
    end

    test "the reassignment first, then the step detached", ctx do
      detach = fn -> Tasks.update(ctx.alice_scope, ctx.s3.ident, %{epic: ""}) end
      assert {{:ok, _}, {:ok, _}} = orchestration_first(ctx, detach)
    end

    test "with the member removed", ctx do
      bob = unboxed(fn -> human_actor(ctx.workspace, ctx.bob).name end)

      remove = fn ->
        Squads.update(ctx.alice_scope, "web-team", %{
          members: [%{name: "keel/fe"}, %{name: "keel/review"}, %{name: bob}]
        })
      end

      assert {{:error, {:orchestration, :not_member, "keel/qa", "web-team"}}, {:ok, _}} =
               other_first(ctx, remove)
    end

    test "start_task with the step detached", ctx do
      start = fn -> Squads.start_task(ctx.scope, ctx.s2.ident) end
      detach = fn -> Tasks.update(ctx.alice_scope, ctx.s2.ident, %{epic: ""}) end

      b = LockHarness.start(detach, pause: :commit)
      LockHarness.await_paused(b)
      a = LockHarness.start(start)
      LockHarness.await_blocked(a)
      LockHarness.continue(b)
      assert {:error, {:orchestration, :outside, _, _}} = LockHarness.result(a)
      assert {:ok, _} = LockHarness.result(b)
    end
  end

  describe "taking over from a retired outside agent" do
    setup ctx do
      unboxed(fn ->
        for name <- ~w(keel/x1 keel/x2) do
          {:ok, _} = Tasks.update(ctx.alice_scope, ctx.s3.ident, %{assignee: name, start: false})
          {:ok, _} = Agents.disable(ctx.alice_scope, name)
        end
      end)

      :ok
    end

    defp take_over(ctx),
      do: fn -> Tasks.update(ctx.scope, ctx.s3.ident, %{assignee: "keel/qa", start: false}) end

    defp enable(ctx), do: fn -> Agents.enable(ctx.alice_scope, "keel/x2") end

    defp s3(ctx), do: unboxed(fn -> Repo.get!(TaskRow, ctx.s3.id) end)

    defp notes(ctx),
      do:
        unboxed(fn ->
          Repo.aggregate(from(f in Feedback.Entry, where: f.task_id == ^ctx.s3.id), :count)
        end)

    defp agent_id(ctx, name), do: unboxed(fn -> agent_actor(ctx.workspace, name).id end)

    test "enabled first: the takeover waits, then is refused, nothing written", ctx do
      before = notes(ctx)
      b = LockHarness.start(enable(ctx), pause: :commit)
      LockHarness.await_paused(b)
      a = LockHarness.start(take_over(ctx))
      LockHarness.await_blocked(a)
      LockHarness.continue(b)

      assert {:error, {:orchestration, :outside_assignee, _, "keel/x2"}} = LockHarness.result(a)
      assert {:ok, _} = LockHarness.result(b)
      assert s3(ctx).assignee_id == agent_id(ctx, "keel/x2")
      assert notes(ctx) == before
    end

    test "the takeover first: enabling waits for it", ctx do
      a = LockHarness.start(take_over(ctx), pause: :commit)
      LockHarness.await_paused(a)
      b = LockHarness.start(enable(ctx))
      LockHarness.await_blocked(b)
      LockHarness.continue(a)

      assert {:ok, _} = LockHarness.result(a)
      assert {:ok, _} = LockHarness.result(b)
      assert s3(ctx).assignee_id == ctx.qa.id
    end

    test "reassigned between the guess and the task lock: taken again", ctx do
      hook = fn
        {:orchestration_guess, 1} -> reassign!(ctx, ctx.s3, "keel/x1")
        _other -> :ok
      end

      assert {:ok, _} = unboxed(fn -> with_hook(hook, take_over(ctx)) end)
      assert s3(ctx).assignee_id == ctx.qa.id
    end

    test "reassigned every round: busy after 3, nothing written", ctx do
      names = %{1 => "keel/x1", 2 => "keel/x2", 3 => "keel/x1"}

      hook = fn
        {:orchestration_guess, n} -> reassign!(ctx, ctx.s3, names[n])
        _other -> :ok
      end

      assert {:error, :busy} = unboxed(fn -> with_hook(hook, take_over(ctx)) end)
      assert s3(ctx).assignee_id == agent_id(ctx, "keel/x1")
    end
  end
end
