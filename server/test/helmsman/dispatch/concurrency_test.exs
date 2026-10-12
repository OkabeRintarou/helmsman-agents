defmodule Helmsman.Dispatch.ConcurrencyTest do
  # Assigning a task to a managed agent races with archiving the agent and
  # with disabling its runtime (decision 3 step 2, decision 8). Each side
  # runs on a connection of its own and holds its transaction open until
  # the test lets it commit.
  use ExUnit.Case, async: false

  import Ecto.Query
  import Helmsman.ProjectsFixtures
  import Helmsman.RunsFixtures

  alias Helmsman.{Agents, CommittedData, Repo, Runtimes, Tasks, Tx}
  alias Helmsman.Agents.AgentProfile
  alias Helmsman.Daemons.Runtime
  alias Helmsman.Runs.Run

  setup do
    ctx =
      CommittedData.unboxed(fn ->
        ctx = dispatch_fixture()
        task = task_fixture(ctx.alice_scope, ctx.project.key)
        Map.merge(ctx, %{task: task, runtime_id: profile(ctx.agent).runtime_id})
      end)

    on_exit(fn -> CommittedData.delete_user_data!([ctx.alice.id]) end)
    Map.put(ctx, :parent, self())
  end

  defp start(fun, hold?) do
    parent = self()
    fun = if hold?, do: held_open(fun, parent), else: fun

    Task.async(fn ->
      CommittedData.unboxed(fn ->
        send(parent, {:backend, self(), CommittedData.backend_pid()})
        fun.()
      end)
    end)
  end

  # `fun` in a transaction kept open until the test sends `:continue`.
  defp held_open(fun, parent), do: fn -> Tx.run(fn -> hold(fun.(), parent) end) end

  defp hold(result, parent) do
    send(parent, {:held, self()})

    receive do
      :continue -> result
    end
  end

  defp backend(%Task{pid: pid}) do
    assert_receive {:backend, ^pid, backend}, 5_000
    backend
  end

  defp held(%Task{pid: pid}), do: assert_receive({:held, ^pid}, 5_000)

  defp assign(ctx), do: Tasks.update(ctx.alice_scope, ctx.task.ident, %{assignee: "keel/dev"})
  defp archive(ctx), do: Agents.archive(ctx.alice_scope, "keel/dev")
  defp disable_runtime(ctx), do: Runtimes.disable(ctx.alice_scope, ctx.runtime_id)

  # First holds its transaction open, second waits for its lock; then the
  # first commits.
  defp race(first, second) do
    first = start(first, true)
    backend(first)
    held(first)

    second = start(second, false)
    CommittedData.await_lock_wait(backend(second))
    send(first.pid, :continue)
    {Task.await(first, 5_000), Task.await(second, 5_000)}
  end

  # Never a queued run on a disabled runtime or an archived agent.
  defp assert_no_stranded_runs(ctx) do
    stranded =
      CommittedData.unboxed(fn ->
        Repo.all(
          from(r in Run,
            join: rt in Runtime,
            on: rt.id == r.runtime_id,
            join: p in AgentProfile,
            on: p.actor_id == r.agent_id,
            where: r.task_id == ^ctx.task.id and r.status == :queued,
            where: not is_nil(rt.disabled_at) or not is_nil(p.archived_at)
          )
        )
      end)

    assert stranded == []
  end

  defp runs(ctx), do: CommittedData.unboxed(fn -> runs_of(ctx.task.id) end)

  test "archive first: the assignment waits, then the agent is disabled", ctx do
    {archived, assigned} = race(fn -> archive(ctx) end, fn -> assign(ctx) end)
    assert {:ok, _} = archived
    assert {:error, changeset} = assigned
    assert {"is disabled", _} = changeset.errors[:assignee]
    assert runs(ctx) == []
    assert_no_stranded_runs(ctx)
  end

  test "assignment first: archiving waits, then cancels the run", ctx do
    {assigned, archived} = race(fn -> assign(ctx) end, fn -> archive(ctx) end)
    assert {:ok, %{dispatch: [%{result: :queued}]}} = assigned
    assert {:ok, _} = archived
    assert [%Run{status: :cancelled, failure_reason: :obsolete}] = runs(ctx)
    assert_no_stranded_runs(ctx)
  end

  test "runtime disabled first: the assignment waits, then sees it disabled", ctx do
    {disabled, assigned} = race(fn -> disable_runtime(ctx) end, fn -> assign(ctx) end)
    assert {:ok, _} = disabled
    assert {:ok, %{dispatch: [%{result: :skipped, reason: :runtime_disabled}]}} = assigned
    assert runs(ctx) == []
    assert_no_stranded_runs(ctx)
  end

  test "assignment first: disabling the runtime waits, then cancels the run", ctx do
    {assigned, disabled} = race(fn -> assign(ctx) end, fn -> disable_runtime(ctx) end)
    assert {:ok, %{dispatch: [%{result: :queued}]}} = assigned
    assert {:ok, _} = disabled
    assert [%Run{status: :cancelled, failure_reason: :obsolete}] = runs(ctx)
    assert_no_stranded_runs(ctx)
  end
end
