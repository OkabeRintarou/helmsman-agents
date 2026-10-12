defmodule Helmsman.Runs.ReadSnapshotTest do
  # add-run-read-models, code review 1: one call of `list_open/3` or
  # `list_finished/3` reads its runs and their total in one snapshot. The
  # reader is paused after each of its queries in turn while another
  # connection commits a real claim or finish.
  use ExUnit.Case, async: false

  import Ecto.Query

  import Helmsman.ProjectsFixtures
  import Helmsman.RunsFixtures

  alias Helmsman.{CommittedData, Repo, Runs}
  alias Helmsman.Runs.Run
  alias HelmsmanProtocol.Report

  setup do
    ctx =
      CommittedData.unboxed(fn ->
        ctx = dispatch_fixture()
        Map.put(ctx, :dctx, daemon_ctx(daemon_of(ctx.agent)))
      end)

    on_exit(fn -> CommittedData.delete_user_data!([ctx.alice.id]) end)
    ctx
  end

  defp new_task_run(ctx) do
    CommittedData.unboxed(fn ->
      task = task_fixture(ctx.alice_scope, ctx.project.key)
      {task, run_fixture(ctx.agent, %{task_id: task.id})}
    end)
  end

  defp claim!(ctx, run) do
    CommittedData.unboxed(fn ->
      {:ok, [_]} = Runs.claim(ctx.dctx, "http://localhost")
      assert Repo.get!(Run, run.id).status == :claimed
    end)
  end

  defp finish!(ctx, run) do
    CommittedData.unboxed(fn ->
      {:ok, report} = Report.Finished.new(%{run_id: run.id, status: :succeeded})
      :ok = Runs.finish(ctx.dctx, report)
    end)
  end

  defp cancel!(run) do
    CommittedData.unboxed(fn ->
      Repo.update_all(from(r in Run, where: r.id == ^run.id), set: [status: :cancelled])
    end)
  end

  defp queries(read) do
    {_result, n} = CommittedData.unboxed(fn -> Helmsman.QueryCount.count(read) end)
    n
  end

  @doc false
  def pause_at(_event, _measurements, _meta, {reader, nth, parent}) do
    if self() == reader, do: count_query(nth, parent)
  end

  defp count_query(nth, parent) do
    n = Process.get(:snapshot_queries, 0) + 1
    Process.put(:snapshot_queries, n)
    if n == nth, do: wait_continue(parent)
  end

  defp wait_continue(parent) do
    send(parent, {:paused, self()})
    receive do: (:continue -> :ok), after: (5_000 -> raise("barrier timeout"))
  end

  # Runs `read` on a connection of its own, paused after its `nth` query
  # until `between` has committed on another one.
  defp read_around(nth, read, between) do
    parent = self()

    reader =
      Task.async(fn ->
        CommittedData.unboxed(fn ->
          handler = {__MODULE__, self()}
          me = self()

          :telemetry.attach(
            handler,
            [:helmsman, :repo, :query],
            &__MODULE__.pause_at/4,
            {me, nth, parent}
          )

          try do
            read.()
          after
            :telemetry.detach(handler)
          end
        end)
      end)

    # How many queries a read makes depends on what it finds: a read that
    # ends before its `nth` query is not paused.
    ref = reader.ref

    receive do
      {:paused, pid} ->
        between.()
        send(pid, :continue)
        {:paused, Task.await(reader, 5_000)}

      {^ref, result} ->
        Process.demonitor(ref, [:flush])
        between.()
        {:ran, result}
    after
      5_000 -> flunk("the read neither paused nor ended")
    end
  end

  defp open_ids(%{active: active, pending: pending}),
    do: Enum.map(active, & &1.id) ++ Enum.map(pending, & &1.id)

  test "list_open: a run claimed during the read is listed exactly once", ctx do
    {task, run} = new_task_run(ctx)
    n = queries(fn -> Runs.list_open(ctx.alice_scope, {:task, task.ident}) end)
    cancel!(run)

    paused =
      for nth <- 1..n, target <- [:task, :agent] do
        {task, run} = new_task_run(ctx)
        target = if target == :task, do: {:task, task.ident}, else: {:agent, "keel/dev"}

        {paused?, {:ok, open}} =
          read_around(nth, fn -> Runs.list_open(ctx.alice_scope, target) end, fn ->
            claim!(ctx, run)
          end)

        assert Enum.count(open_ids(open), &(&1 == run.id)) == 1,
               "query #{nth}, #{inspect(target)}: #{inspect(open)}"

        assert open.pending_total == length(open.pending)
        # At most two active runs per agent: make room for the next claim.
        cancel!(run)
        {nth, paused?}
      end

    # The target and the runs with their total are read by the first two.
    assert {1, :paused} in paused and {2, :paused} in paused
  end

  test "list_finished: a run finished during the read agrees with the total", ctx do
    {task, run} = new_task_run(ctx)
    cancel!(run)
    n = queries(fn -> Runs.list_finished(ctx.alice_scope, {:task, task.ident}) end)

    paused =
      for nth <- 1..n, target <- [:task, :agent] do
        {task, run} = new_task_run(ctx)
        claim!(ctx, run)
        CommittedData.unboxed(fn -> {:ok, :proceed} = Runs.starting(ctx.dctx, run.id) end)
        target = if target == :task, do: {:task, task.ident}, else: {:agent, "keel/dev"}

        {paused?, {:ok, %{runs: runs, total: total}}} =
          read_around(nth, fn -> Runs.list_finished(ctx.alice_scope, target) end, fn ->
            finish!(ctx, run)
          end)

        assert length(runs) == total, "query #{nth}, #{inspect(target)}"
        {nth, paused?}
      end

    assert {1, :paused} in paused and {2, :paused} in paused
  end
end
