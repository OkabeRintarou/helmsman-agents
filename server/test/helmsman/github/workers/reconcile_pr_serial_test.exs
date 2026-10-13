defmodule Helmsman.GitHub.Workers.ReconcilePRSerialTest do
  # add-pr-reconcile-merge 1.4: reconciliations of a task are serial
  # (decision 3). The holders run on connections of their own outside the
  # sandbox, so this module is not async (the pool would run dry).
  use Helmsman.DataCase, async: false
  use Oban.Testing, repo: Helmsman.Repo

  import Helmsman.PullRequestFixtures

  alias Helmsman.FakeGitHub
  alias Helmsman.GitHub.Workers.ReconcilePR

  setup do
    ctx = pr_fixture()
    Map.put(ctx, :fake, FakeGitHub.start())
  end

  defp reconcile(ctx), do: perform_job(ReconcilePR, %{task_id: ctx.task.id})

  test "a second job of the same task snoozes while the first holds the lock", ctx do
    parent = self()

    holder =
      Elixir.Task.async(fn ->
        Helmsman.CommittedData.unboxed(fn ->
          ReconcilePR.serially(ctx.task.id, fn ->
            send(parent, :locked)
            receive do: (:release -> :ok)
          end)
        end)
      end)

    assert_receive :locked, 5_000
    assert {:snooze, 5} = reconcile(ctx)
    send(holder.pid, :release)
    assert :ok = Elixir.Task.await(holder)
    assert :ok = reconcile(ctx)
  end

  test "a killed holder's lock is released with its connection", ctx do
    parent = self()

    # The pool logs the disconnect of the killed holder's connection.
    ExUnit.CaptureLog.capture_log(fn ->
      pid =
        spawn(fn ->
          Helmsman.CommittedData.unboxed(fn ->
            ReconcilePR.serially(ctx.task.id, fn ->
              send(parent, :locked)
              Process.sleep(:infinity)
            end)
          end)
        end)

      assert_receive :locked, 5_000
      assert {:snooze, 5} = reconcile(ctx)
      Process.exit(pid, :kill)

      # Within 5 seconds another reconciliation gets the lock.
      assert Enum.any?(1..50, fn _ ->
               Process.sleep(100)

               Helmsman.CommittedData.unboxed(fn ->
                 ReconcilePR.serially(ctx.task.id, fn -> :got end)
               end) == :got
             end)
    end)
  end
end
