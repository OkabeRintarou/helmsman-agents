defmodule Helmsman.Runs.RunEndedRaceTest do
  # A run-token write that waits on a lock while its run ends (or its token
  # is revoked) must not commit (code review 1, P1); a write that got past
  # the check first commits, and ending the run waits for it. Each side
  # runs on a connection of its own outside the sandbox.
  use ExUnit.Case, async: false

  import Ecto.Query
  import Helmsman.ProjectsFixtures
  import Helmsman.RunsFixtures

  alias Helmsman.{CommittedData, Events, Feedback, Repo, Tasks, Tx}
  alias Helmsman.Feedback.Entry
  alias Helmsman.Projects.Project
  alias Helmsman.Runs.{Run, RunToken, RunTokens}
  alias Helmsman.Tasks.Task, as: TaskRow
  alias Helmsman.Tasks.TaskEvent
  alias HelmsmanMCP.Pipeline
  alias HelmsmanMCP.Tools.UpdateTask

  setup do
    ctx =
      CommittedData.unboxed(fn ->
        ctx = dispatch_fixture()
        task = task_fixture(ctx.alice_scope, ctx.project.key, %{title: "before"})

        run =
          run_fixture(ctx.agent, %{
            task_id: task.id,
            status: :running,
            capabilities: ["read", "write_task", "create_tasks"]
          })

        {:ok, token} = RunTokens.issue(run)
        Map.merge(ctx, %{task: task, run: run, token: token})
      end)

    on_exit(fn -> CommittedData.delete_user_data!([ctx.alice.id]) end)
    Events.subscribe(Events.topic(:task, ctx.task.id))
    Events.subscribe(Events.topic(:project, ctx.project.id))
    Events.subscribe(Events.topic(:workspace_runs, ctx.workspace.id))
    ctx
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

  defp hold(result) do
    send(Process.get(:test_parent), {:held, self()})

    receive do
      :continue -> result
    end
  end

  defp held(%Task{pid: pid}), do: assert_receive({:held, ^pid}, 5_000)

  # Holds the row `FOR UPDATE` in an open transaction.
  defp lock_row(queryable, id, parent) do
    start(fn ->
      Process.put(:test_parent, parent)

      Tx.run(fn ->
        Repo.one!(from(r in queryable, where: r.id == ^id, lock: "FOR UPDATE"))
        hold({:ok, :released})
      end)
    end)
  end

  defp end_run(ctx, :terminal),
    do: Repo.update_all(from(r in Run, where: r.id == ^ctx.run.id), set: [status: :succeeded])

  defp end_run(ctx, :revoked), do: RunTokens.revoke(ctx.run.id)

  defp scope(ctx) do
    {:ok, scope} = CommittedData.unboxed(fn -> RunTokens.scope(ctx.token) end)
    scope
  end

  defp writes(ctx) do
    [
      {"update_task over MCP", TaskRow, ctx.task.id,
       fn scope ->
         Pipeline.call_module(
           UpdateTask,
           %{"task_id" => ctx.task.ident, "title" => "after"},
           scope,
           nil
         )
       end},
      {"transition", TaskRow, ctx.task.id, &Tasks.transition(&1, ctx.task.ident, :in_progress)},
      {"add feedback", TaskRow, ctx.task.id,
       &Feedback.add(&1, ctx.task.ident, %{content: "late"})},
      {"create task (no task lock)", Project, ctx.project.id,
       &Tasks.create(&1, ctx.project.key, %{title: "late"})}
    ]
  end

  defp snapshot(ctx) do
    CommittedData.unboxed(fn ->
      task = Repo.get!(TaskRow, ctx.task.id)

      {task.title, task.status, task.lock_version,
       Repo.aggregate(from(f in Entry, where: f.task_id == ^ctx.task.id), :count),
       Repo.aggregate(from(e in TaskEvent, where: e.task_id == ^ctx.task.id), :count),
       Repo.get!(Project, ctx.project.id).task_seq}
    end)
  end

  for ending <- [:terminal, :revoked] do
    test "the run ends (#{ending}) while each write waits on its lock: nothing is written",
         ctx do
      for {label, queryable, id, write} <- writes(ctx) do
        before = snapshot(ctx)
        CommittedData.unboxed(fn -> reset(ctx) end)
        scope = scope(ctx)

        locker = lock_row(queryable, id, self())
        backend(locker)
        held(locker)

        writer = start(fn -> write.(scope) end)
        CommittedData.await_lock_wait(backend(writer))
        CommittedData.unboxed(fn -> end_run(ctx, unquote(ending)) end)

        assert {:error, :unauthorized} =
                 CommittedData.unboxed(fn -> RunTokens.authenticate(ctx.token) end)

        send(locker.pid, :continue)
        assert {:ok, :released} = Task.await(locker, 5_000)

        case Task.await(writer, 5_000) do
          {:error, text} when is_binary(text) -> assert text =~ "This run has ended", label
          other -> assert other == {:error, :run_ended}, label
        end

        assert snapshot(ctx) == before, label
        refute_received {:task_updated, _}
        refute_received {:task_created, _}
        refute_received {:feedback_added, _}
        refute_received {:task_transitioned, _}
      end
    end
  end

  # A fresh, valid run state for the next write of a loop.
  defp reset(ctx) do
    Repo.update_all(from(r in Run, where: r.id == ^ctx.run.id), set: [status: :running])
    Repo.update_all(from(t in RunToken, where: t.run_id == ^ctx.run.id), set: [revoked_at: nil])
  end

  test "the token expires while the write waits for the run row: nothing is written", ctx do
    expires_at = DateTime.add(DateTime.utc_now(), 500, :millisecond)

    CommittedData.unboxed(fn ->
      Repo.update_all(from(t in RunToken, where: t.run_id == ^ctx.run.id),
        set: [expires_at: expires_at]
      )
    end)

    scope = scope(ctx)
    before = snapshot(ctx)

    # The write locks the task freely, then waits in its final check for
    # the run row.
    locker = lock_row(Run, ctx.run.id, self())
    backend(locker)
    held(locker)

    writer = start(fn -> Tasks.update(scope, ctx.task.ident, %{title: "after expiry"}) end)
    CommittedData.await_lock_wait(backend(writer))

    # Only real time can make the token expire; the order is set by the locks.
    Process.sleep(max(DateTime.diff(expires_at, DateTime.utc_now(), :millisecond), 0) + 50)

    assert {:error, :unauthorized} =
             CommittedData.unboxed(fn -> RunTokens.authenticate(ctx.token) end)

    send(locker.pid, :continue)
    assert {:ok, :released} = Task.await(locker, 5_000)
    assert {:error, :run_ended} = Task.await(writer, 5_000)
    assert snapshot(ctx) == before
    refute_received {:task_updated, _}
  end

  for ending <- [:terminal, :revoked] do
    test "a write past the check commits first; ending the run (#{ending}) waits for it", ctx do
      parent = self()
      scope = scope(ctx)

      writer =
        start(fn ->
          Process.put(:test_parent, parent)

          Tx.run(fn ->
            result = Tasks.update(scope, ctx.task.ident, %{title: "in time"})
            hold(result)
          end)
        end)

      backend(writer)
      held(writer)

      ender = start(fn -> end_run(ctx, unquote(ending)) end)
      CommittedData.await_lock_wait(backend(ender))

      send(writer.pid, :continue)
      assert {:ok, %{title: "in time"}} = Task.await(writer, 5_000)
      Task.await(ender, 5_000)

      assert CommittedData.unboxed(fn -> Repo.get!(TaskRow, ctx.task.id).title end) == "in time"
      assert_receive {:task_updated, _}

      assert {:error, :unauthorized} =
               CommittedData.unboxed(fn -> RunTokens.authenticate(ctx.token) end)
    end
  end
end
