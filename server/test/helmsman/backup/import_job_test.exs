defmodule Helmsman.Backup.Import.JobTest do
  use Helmsman.DataCase, async: false
  import Helmsman.AccountsFixtures
  import Helmsman.WorkspacesFixtures
  import Helmsman.ProjectsFixtures
  alias Helmsman.Backup
  alias Helmsman.Backup.{ExportRecord, Files, ImportRecord}
  alias Helmsman.Backup.Workers.{Import, Prune}

  setup do
    user = user_fixture()
    workspace = workspace_fixture(user)
    scope = workspace_scope_fixture(user, workspace)
    path = Path.join(System.tmp_dir!(), "import-job-#{System.unique_integer([:positive])}")
    File.write!(path, "{")
    on_exit(fn -> File.rm(path) end)
    %{scope: scope, path: path, workspace: workspace}
  end

  test "queued imports are exclusive, failures keep audit and delete uploads", ctx do
    assert {:ok, record} = Backup.start_import(ctx.scope, ctx.path, dry_run: true)
    assert record.file_name == Path.basename(ctx.path)
    assert {:error, :busy} = Backup.start_import(ctx.scope, ctx.path)
    {:ok, path} = Files.path(:imports, record.upload)
    assert File.exists?(path)
    assert :ok = Import.perform(%Oban.Job{args: %{"id" => record.id}})
    record = Repo.get!(ImportRecord, record.id)
    assert record.status == :failed
    assert length(record.errors) == 1
    assert record.file_sha256 =~ ~r/^[a-f0-9]{64}$/
    assert record.upload == nil
    refute File.exists?(path)
  end

  test "upload display name is truncated without changing validation options", ctx do
    name = String.duplicate("数据", 150) <> ".json.gz"

    assert {:ok, record} =
             Backup.start_import(ctx.scope, ctx.path,
               file_name: name,
               dry_run: true,
               rename: %{"old" => "new"}
             )

    assert record.file_name == String.slice(name, 0, 255)
    assert record.options["rename"] == %{"old" => "new"}
    assert record.options["dry_run"] == "true"
    refute Map.has_key?(record.options, "file_name")
    assert :ok = Import.perform(%Oban.Job{args: %{"id" => record.id}})
    assert Repo.get!(ImportRecord, record.id).status == :failed
    assert {:error, :invalid_params} = Backup.start_import(ctx.scope, ctx.path, file_name: 42)
  end

  test "prune marks deleted job interrupted and removes expired and orphan artifacts", ctx do
    {:ok, record} = Backup.start_import(ctx.scope, ctx.path)
    {:ok, path} = Files.path(:imports, record.upload)
    Repo.delete_all(from(j in Oban.Job, where: j.worker == "Helmsman.Backup.Workers.Import"))
    {:ok, file} = Files.create(:exports, ctx.workspace.id)
    File.close(file.io)
    expiry = DateTime.add(DateTime.utc_now(), -1)

    exported =
      Repo.insert!(%ExportRecord{
        workspace_id: ctx.workspace.id,
        user_id: ctx.scope.user.id,
        status: :succeeded,
        file: file.name,
        expires_at: expiry
      })

    {:ok, orphan} = Files.create(:imports, ctx.workspace.id)
    File.close(orphan.io)
    File.touch!(orphan.path, DateTime.to_unix(DateTime.utc_now()) - 7200)
    assert :ok = Prune.perform(%Oban.Job{})
    assert Repo.get!(ImportRecord, record.id).errors == [%{"reason" => "interrupted"}]
    refute File.exists?(path)
    refute File.exists?(orphan.path)
    refute File.exists?(file.path)
    refute Repo.get(ExportRecord, exported.id)
  end

  test "background dry run retains a successful report and leaves no tasks", ctx do
    source = workspace_fixture(ctx.scope.user)
    source_scope = workspace_scope_fixture(ctx.scope.user, source)
    project = project_fixture(source_scope)
    task_fixture(source_scope, project.key)
    old = Application.get_env(:helmsman, :backup_sandbox)
    Application.put_env(:helmsman, :backup_sandbox, true)
    on_exit(fn -> Application.put_env(:helmsman, :backup_sandbox, old) end)
    {:ok, _} = Backup.export_to_file(source, ctx.path)
    {:ok, record} = Backup.start_import(ctx.scope, ctx.path, dry_run: true)
    assert :ok = Import.perform(%Oban.Job{args: %{"id" => record.id}})
    assert Repo.get!(ImportRecord, record.id).status == :succeeded
    assert Repo.get!(ImportRecord, record.id).report["counts"]["tasks"]["created"] == 1

    assert Repo.aggregate(
             from(t in Helmsman.Tasks.Task, where: t.workspace_id == ^ctx.workspace.id),
             :count
           ) == 0
  end

  test "synchronous write exceptions roll back and settle the audit", ctx do
    source = workspace_fixture(ctx.scope.user)
    source_scope = workspace_scope_fixture(ctx.scope.user, source)
    project = project_fixture(source_scope)
    task_fixture(source_scope, project.key)
    old = Application.get_env(:helmsman, :backup_sandbox)
    Application.put_env(:helmsman, :backup_sandbox, true)
    on_exit(fn -> Application.put_env(:helmsman, :backup_sandbox, old) end)
    {:ok, _} = Backup.export_to_file(source, ctx.path)

    Process.put(:helmsman_test_hook, fn
      :import_audited -> raise "injected failure after data and audit writes"
      _ -> :ok
    end)

    assert ExUnit.CaptureLog.capture_log(fn ->
             assert {:error, :import_failed} = Backup.import_file(ctx.scope, ctx.path)
           end) =~ "backup import failed"

    record = Repo.one!(from(i in ImportRecord, where: i.workspace_id == ^ctx.workspace.id))
    assert record.status == :failed
    assert record.errors == [%{"reason" => "import_failed"}]
    assert record.file_sha256 =~ ~r/^[0-9a-f]{64}$/

    assert Repo.aggregate(
             from(t in Helmsman.Tasks.Task, where: t.workspace_id == ^ctx.workspace.id),
             :count
           ) == 0

    Process.delete(:helmsman_test_hook)
  end
end
