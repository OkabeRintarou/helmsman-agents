defmodule Helmsman.Backup.PruneRaceTest do
  use ExUnit.Case, async: false
  import Ecto.Query
  import Helmsman.AccountsFixtures
  import Helmsman.WorkspacesFixtures
  import Helmsman.ProjectsFixtures
  alias Helmsman.{Backup, CommittedData, Repo}
  alias Helmsman.Backup.{ExportRecord, ImportRecord}
  alias Helmsman.Backup.Workers.{Export, Import, Prune}

  setup do
    ctx =
      CommittedData.unboxed(fn ->
        user = user_fixture()
        workspace = workspace_fixture(user)
        scope = workspace_scope_fixture(user, workspace)
        project = project_fixture(scope)
        task_fixture(scope, project.key)
        %{user: user, workspace: workspace, scope: scope}
      end)

    path = Path.join(System.tmp_dir!(), "prune-race-#{System.unique_integer([:positive])}.gz")

    on_exit(fn ->
      File.rm(path)
      CommittedData.delete_user_data!([ctx.user.id])
    end)

    Map.put(ctx, :path, path)
  end

  for {kind, worker, schema} <- [
        {:imports, Import, ImportRecord},
        {:exports, Export, ExportRecord}
      ] do
    @kind kind
    @worker worker
    @schema schema
    test "#{kind} completion after candidate scan retains success and artifact", ctx do
      record =
        CommittedData.unboxed(fn ->
          if @kind == :imports do
            {:ok, _} = Backup.export_to_file(ctx.workspace, ctx.path)
            {:ok, record} = Backup.start_import(ctx.scope, ctx.path)
            record
          else
            {:ok, record} = Backup.request_export(ctx.scope)
            record
          end
        end)

      parent = self()
      kind = @kind

      pruner =
        Task.async(fn ->
          Process.put(:helmsman_test_hook, fn
            {:prune_candidates, ^kind} ->
              send(parent, {:scan_complete, self()})
              receive do: (:continue -> :ok)

            _ ->
              :ok
          end)

          CommittedData.unboxed(fn -> Prune.perform(%Oban.Job{}) end)
        end)

      assert_receive {:scan_complete, pid}, 5000

      succeeded =
        CommittedData.unboxed(fn ->
          assert :ok = @worker.perform(%Oban.Job{args: %{"id" => record.id}})

          Repo.update_all(
            from(j in Oban.Job,
              where:
                j.worker == ^inspect(@worker) and
                  fragment("(?->>'id')::bigint", j.args) == ^record.id
            ),
            set: [state: "completed"]
          )

          Repo.get!(@schema, record.id)
        end)

      assert succeeded.status == :succeeded
      send(pid, :continue)
      assert :ok = Task.await(pruner, 5000)
      assert CommittedData.unboxed(fn -> Repo.get!(@schema, record.id) end) == succeeded

      if @kind == :exports do
        assert {:ok, file} =
                 CommittedData.unboxed(fn -> Backup.export_file(ctx.scope, record.id) end)

        assert File.exists?(file.path)
        on_exit(fn -> File.rm(file.path) end)
      else
        assert succeeded.report["counts"]["tasks"]["unchanged"] == 1
      end
    end
  end
end
