defmodule Helmsman.Runs.ClaimDependenciesTest do
  # add-dependency-dispatch 1.7: claiming checks the dependencies of a run
  # there only for assignment triggers, under a graph lock it only tries
  # (decision 7).
  use Helmsman.DataCase, async: true

  import Helmsman.DependencyFixtures
  import Helmsman.ProjectsFixtures
  import Helmsman.RunsFixtures

  alias Helmsman.Links.Link
  alias Helmsman.{Locks, Runs}

  # No domain write that takes the graph lock: in the sandbox it would be
  # held by the test's connection until the end.
  setup do
    ctx = dispatch_fixture()
    [bos1, web2] = for _ <- 1..2, do: task(ctx)
    link!(ctx, web2, bos1)
    Map.merge(ctx, %{daemon: daemon_of(ctx.agent), bos1: bos1, web2: web2})
  end

  # A task assigned to keel/dev.
  defp task(ctx) do
    task = task_fixture(ctx.alice_scope, ctx.project.key)
    put_assignee!(task, ctx.agent.id)
    task
  end

  defp link!(ctx, from, to) do
    Repo.insert_all(Link, [
      %{
        workspace_id: ctx.workspace.id,
        from_task_id: from.id,
        to_task_id: to.id,
        type: :depends_on,
        actor_id: ctx.alice_scope.actor.id
      }
    ])
  end

  defp claim(ctx), do: Runs.claim(daemon_ctx(ctx.daemon), "http://localhost:4000")
  defp ids({:ok, specs}), do: specs |> Enum.map(& &1.run_id) |> Enum.sort()

  # Whether this connection holds the workspace graph lock (the sandbox
  # transaction keeps it until the test ends).
  defp graph_held?(ctx) do
    %{rows: [[n]]} =
      Repo.query!(
        "SELECT count(*) FROM pg_locks WHERE locktype = 'advisory' AND pid = pg_backend_pid() " <>
          "AND granted AND ((classid::bigint << 32) | objid::bigint) = $1",
        [Locks.key(:graph, ctx.workspace.id)]
      )

    n > 0
  end

  # Holds the workspace graph lock (session level) on a connection of its
  # own, outside the Repo pool, so that taking it never waits for a pooled
  # connection; returns once it is held. Stopping the connection releases it.
  defp hold_graph_lock!(workspace_id) do
    parent = self()
    key = Locks.key(:graph, workspace_id)

    after_connect = fn conn ->
      Postgrex.query!(conn, "SELECT pg_advisory_lock($1)", [key])
      send(parent, {:graph_held, self()})
    end

    opts =
      Repo.config()
      |> Keyword.drop([:pool, :name])
      |> Keyword.merge(pool_size: 1, backoff_type: :stop, after_connect: after_connect)

    {:ok, conn} = Postgrex.start_link(opts)
    ref = Process.monitor(conn)

    receive do
      {:graph_held, _pid} -> conn
      {:DOWN, ^ref, :process, _pid, reason} -> flunk("lock holder down: #{inspect(reason)}")
    end
  end

  describe "领取时复查依赖" do
    test "排队后才加的依赖", ctx do
      task = task(ctx)
      run = run_with!(ctx, task, :queued, ["assign", "retry_auto"])
      link!(ctx, task, task(ctx))

      assert claim(ctx) == {:ok, []}
      assert run_status(run) == :deferred
      assert graph_held?(ctx)
    end

    test "含手动触发", ctx do
      run = run_with!(ctx, ctx.web2, :queued, ["assign", "manual"])
      assert ids(claim(ctx)) == [run.id]
      refute graph_held?(ctx)
    end

    test "dependencies satisfied: claimed", ctx do
      put_status!(ctx.bos1, :done)
      run = run_with!(ctx, ctx.web2, :queued, ["assign", "unblocked"])
      assert ids(claim(ctx)) == [run.id]
    end

    test "no outgoing link: no graph lock", ctx do
      run = run_with!(ctx, task(ctx), :queued, ["assign"])
      assert ids(claim(ctx)) == [run.id]
      refute graph_held?(ctx)
    end

    test "图锁被占用: returns at once, the run stays queued, the others are claimed", ctx do
      Repo.update_all(Helmsman.Agents.AgentProfile, set: [max_concurrency: 5])
      blocked = run_with!(ctx, ctx.web2, :queued, ["assign"], %{priority: 3})
      other = run_with!(ctx, task(ctx), :queued, ["assign"])
      holder = hold_graph_lock!(ctx.workspace.id)

      # Not waiting is checked by the lock wait, not by the elapsed time: a
      # claim waiting for the graph lock fails with `lock_not_available`.
      Repo.query!("SET LOCAL lock_timeout = '1s'")
      result = claim(ctx)
      Repo.query!("SET LOCAL lock_timeout = DEFAULT")
      GenServer.stop(holder)

      assert ids(result) == [other.id]
      assert run_status(blocked) == :queued
    end
  end
end
