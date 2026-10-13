defmodule Mix.Tasks.Helmsman.BackupTest do
  use Helmsman.DataCase, async: false
  import Helmsman.AccountsFixtures
  import Helmsman.WorkspacesFixtures
  import Helmsman.ProjectsFixtures
  alias Helmsman.{Backup, Tasks}
  alias Helmsman.Backup.Import.Read
  alias Helmsman.Backup.Workers.Export, as: ExportWorker
  alias Mix.Tasks.Helmsman.{Export, ImportBosun}
  alias Mix.Tasks.Helmsman.Import, as: ImportTask

  setup do
    old_shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)
    old = Application.get_env(:helmsman, :backup_sandbox)
    Application.put_env(:helmsman, :backup_sandbox, true)
    user = user_fixture()
    workspace = workspace_fixture(user)
    scope = workspace_scope_fixture(user, workspace)
    project = project_fixture(scope)
    task_fixture(scope, project.key)
    path = Path.join(System.tmp_dir!(), "backup-cli-#{System.unique_integer([:positive])}.gz")

    on_exit(fn ->
      File.rm(path)
      Mix.shell(old_shell)
      Application.put_env(:helmsman, :backup_sandbox, old)
    end)

    %{user: user, workspace: workspace, scope: scope, path: path}
  end

  test "export CLI produces the same snapshot contract and fails on missing workspace", ctx do
    assert :ok = Export.run(["--workspace", ctx.workspace.slug, "--out", ctx.path])
    assert_receive {:mix_shell, :info, [json]}
    assert Jason.decode!(json)["counts"]["tasks"] == 1
    assert {:ok, data} = Read.file(ctx.path)
    assert data["format"] == "helmsman-export"
    {:ok, record} = Backup.request_export(ctx.scope)
    :ok = ExportWorker.perform(%Oban.Job{args: %{"id" => record.id}})
    {:ok, file} = Backup.export_file(ctx.scope, record.id)
    on_exit(fn -> File.rm(file.path) end)
    {:ok, worker_data} = Read.file(file.path)
    assert Map.delete(data, "exported_at") == Map.delete(worker_data, "exported_at")
    assert catch_exit(Export.run(["--workspace", "missing"])) == {:shutdown, 1}
  end

  test "dry run prints a report without changing tasks and replace requires confirm", ctx do
    {:ok, _} = Backup.export_to_file(ctx.workspace, ctx.path)
    target = workspace_fixture(ctx.user)
    args = [ctx.path, "--workspace", target.slug, "--as", ctx.user.email]

    assert :ok =
             ImportTask.run(
               args ++ ["--dry-run", "--rename", ctx.scope.actor.name <> "=historical"]
             )

    assert_receive {:mix_shell, :info, [json]}
    assert Jason.decode!(json)["counts"]["tasks"]["created"] == 1
    assert Repo.aggregate(from(t in Tasks.Task, where: t.workspace_id == ^target.id), :count) == 0
    assert catch_exit(ImportTask.run(args ++ ["--mode", "replace"])) == {:shutdown, 1}
  end

  test "non-admin --as cannot import", ctx do
    user = user_fixture()
    member_fixture(ctx.workspace, user, :member)
    {:ok, _} = Backup.export_to_file(ctx.workspace, ctx.path)

    assert catch_exit(
             ImportTask.run([ctx.path, "--workspace", ctx.workspace.slug, "--as", user.email])
           ) == {:shutdown, 1}
  end

  test "bosun CLI maps synthetic user to importer and applies explicit rename", ctx do
    assert :ok =
             ImportBosun.run([
               "test/fixtures/bosun/export-v2.json",
               "--workspace",
               ctx.workspace.slug,
               "--as",
               ctx.user.email,
               "--rename",
               "user=historical"
             ])

    assert_receive {:mix_shell, :info, [json]}
    assert Jason.decode!(json)["counts"]["tasks"]["created"] == 3

    actor =
      Repo.one!(
        from(a in Helmsman.Actors.Actor,
          where: a.workspace_id == ^ctx.workspace.id and a.name == "historical"
        )
      )

    assert actor.kind == :human and is_nil(actor.user_id)

    assert Repo.one!(
             from(t in Tasks.Task,
               where: t.workspace_id == ^ctx.workspace.id and t.ident == "BOS-1"
             )
           ).created_by_id == actor.id
  end
end
