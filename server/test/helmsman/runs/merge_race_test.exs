defmodule Helmsman.Runs.MergeRaceTest do
  # Concurrent triggers of one (task, agent, lane), and a trigger racing
  # with the claim of the run it would merge into. Each side runs on a
  # connection of its own outside the sandbox.
  use ExUnit.Case, async: false

  import Ecto.Query
  import Helmsman.ProjectsFixtures
  import Helmsman.RunsFixtures

  alias Helmsman.{CommittedData, Dispatch, Repo, Runs, Tx}
  alias Helmsman.Runs.Run

  setup do
    ctx =
      CommittedData.unboxed(fn ->
        ctx = dispatch_fixture(%{access: "workspace"})
        {carol, carol_scope} = member_scope_fixture(ctx.workspace)
        task = task_fixture(ctx.alice_scope, ctx.project.key)
        Map.merge(ctx, %{carol: carol, carol_scope: carol_scope, task: task})
      end)

    on_exit(fn -> CommittedData.delete_user_data!([ctx.alice.id, ctx.carol.id]) end)
    Map.put(ctx, :parent, self())
  end

  defp start(fun) do
    parent = self()

    Task.async(fn ->
      CommittedData.unboxed(fn ->
        send(parent, {:backend, self(), CommittedData.backend_pid()})
        fun.()
      end)
    end)
  end

  defp backend(%Task{pid: pid}) do
    assert_receive {:backend, ^pid, backend}, 5_000
    backend
  end

  defp wait_go do
    receive do
      :go -> :ok
    end
  end

  defp runs(ctx), do: CommittedData.unboxed(fn -> runs_of(ctx.task.id) end)

  test "two triggers at once: one queued run with both", ctx do
    tasks =
      for scope <- [ctx.alice_scope, ctx.carol_scope] do
        start(fn ->
          wait_go()
          Dispatch.run_agent(scope, "keel/dev", ctx.task.ident, nil)
        end)
      end

    Enum.each(tasks, &backend/1)
    Enum.each(tasks, &send(&1.pid, :go))

    results = Enum.map(tasks, &Task.await(&1, 5_000))

    assert results |> Enum.map(fn {:ok, %{outcome: o}} -> o.result end) |> Enum.sort() == [
             :merged,
             :queued
           ]

    assert [%Run{status: :queued, triggers: [_, _]}] = runs(ctx)
  end

  test "an insert without the task lock merges into a concurrent insert", ctx do
    attrs = %{
      workspace_id: ctx.workspace.id,
      agent_id: ctx.agent.id,
      runtime_id: CommittedData.unboxed(fn -> profile(ctx.agent).runtime_id end),
      task_id: ctx.task.id,
      lane: :work,
      trigger: %{"kind" => "retry"},
      root_initiator_user_id: ctx.alice.id,
      causal_agent_ids: [ctx.agent.id],
      capabilities: ["read"],
      priority: 1
    }

    first =
      start(fn ->
        Tx.run(fn ->
          result = Runs.upsert_pending(attrs, rate_limit?: false)
          send(ctx.parent, {:inserted, self()})
          wait_go()
          {:ok, result}
        end)
      end)

    backend(first)
    pid = first.pid
    assert_receive {:inserted, ^pid}, 5_000

    second =
      start(fn -> Tx.run(fn -> {:ok, Runs.upsert_pending(attrs, rate_limit?: false)} end) end)

    CommittedData.await_lock_wait(backend(second))
    send(first.pid, :go)

    assert {:ok, {:queued, %Run{id: id}}} = Task.await(first, 5_000)
    assert {:ok, {:merged, %Run{id: ^id}}} = Task.await(second, 5_000)
    assert [%Run{triggers: [_, _]}] = runs(ctx)
  end

  for {label, old, expected} <- [
        {"at the limit: rate_limited", 19, :skipped},
        {"under the limit: a new queued run", 0, :queued}
      ] do
    test "the run to merge into is being claimed, #{label}", ctx do
      queued =
        CommittedData.unboxed(fn ->
          for _ <- 1..unquote(old)//1,
              do: run_fixture(ctx.agent, %{task_id: ctx.task.id, status: :succeeded})

          run_fixture(ctx.agent, %{task_id: ctx.task.id})
        end)

      claimer =
        start(fn ->
          Tx.run(fn ->
            Repo.one!(from(r in Run, where: r.id == ^queued.id, lock: "FOR UPDATE"))
            send(ctx.parent, {:locked, self()})
            wait_go()

            Repo.update_all(from(r in Run, where: r.id == ^queued.id), set: [status: :claimed])
            {:ok, :claimed}
          end)
        end)

      backend(claimer)
      pid = claimer.pid
      assert_receive {:locked, ^pid}, 5_000

      trigger =
        start(fn -> Dispatch.run_agent(ctx.carol_scope, "keel/dev", ctx.task.ident, nil) end)

      CommittedData.await_lock_wait(backend(trigger))
      send(claimer.pid, :go)

      assert {:ok, :claimed} = Task.await(claimer, 5_000)
      assert {:ok, %{outcome: outcome}} = Task.await(trigger, 5_000)
      assert outcome.result == unquote(expected)
      refute outcome.result == :merged

      if unquote(expected) == :skipped do
        assert outcome.reason == :rate_limited
      else
        assert outcome.run_id != queued.id
      end

      assert %Run{status: :claimed, triggers: []} =
               CommittedData.unboxed(fn -> Repo.get!(Run, queued.id) end)
    end
  end
end
