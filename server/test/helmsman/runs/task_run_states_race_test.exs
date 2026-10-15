defmodule Helmsman.Runs.TaskRunStatesRaceTest do
  use Helmsman.DataCase, async: false
  import Helmsman.RunsFixtures
  import Helmsman.ProjectsFixtures
  alias Helmsman.{CommittedData, Repo, Runs}

  setup do
    ctx =
      CommittedData.unboxed(fn ->
        ctx = dispatch_fixture()
        Map.put(ctx, :task, task_fixture(ctx.alice_scope, ctx.project.key))
      end)

    on_exit(fn -> CommittedData.delete_user_data!([ctx.alice.id]) end)
    ctx
  end

  for {initial, final, before, after_state} <- [
        {:queued, :claimed, :queued, :running},
        {:running, :failed, :running, :failed}
      ] do
    test "consistent snapshot during #{initial} → #{final}", ctx do
      initial = unquote(initial)

      run =
        CommittedData.unboxed(fn ->
          older_failure(ctx, initial)

          run_fixture(ctx.agent, %{task_id: ctx.task.id, status: initial})
        end)

      parent = self()

      writer =
        Task.async(fn ->
          CommittedData.unboxed(fn ->
            Repo.transaction(fn ->
              Repo.query!(
                "UPDATE runs SET status = $1, claimed_at = now(), finished_at = now() WHERE id = $2",
                [to_string(unquote(final)), run.id]
              )

              send(parent, :updated)

              receive do
                :commit -> :ok
              after
                5000 -> raise "missing release"
              end
            end)
          end)
        end)

      assert_receive :updated, 5000
      assert {:ok, %{status: unquote(before)}} = read(ctx)
      send(writer.pid, :commit)
      Task.await(writer)
      assert {:ok, %{status: unquote(after_state)}} = read(ctx)
    end
  end

  defp older_failure(ctx, :queued),
    do:
      run_fixture(ctx.agent, %{
        task_id: ctx.task.id,
        status: :failed,
        finished_at: DateTime.add(DateTime.utc_now(), -10)
      })

  defp older_failure(_ctx, _status), do: :ok

  defp read(ctx) do
    CommittedData.unboxed(fn ->
      {:ok, states} = Runs.task_run_states(ctx.alice_scope, [ctx.task.ident])
      {:ok, states[ctx.task.ident]}
    end)
  end
end
