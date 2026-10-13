defmodule Helmsman.BackupTest do
  use Helmsman.DataCase, async: false
  import Helmsman.AccountsFixtures
  import Helmsman.WorkspacesFixtures
  import Helmsman.ProjectsFixtures
  alias Helmsman.{Actors, Backup, Feedback, Tasks}
  alias Helmsman.Backup.{Format, ImportRecord}
  alias Helmsman.Backup.Import.{Read, Validate}
  alias Helmsman.Backup.Workers.Export, as: ExportWorker
  alias HelmsmanMCP.Tools.ListActors

  setup do
    old = Application.get_env(:helmsman, :backup_sandbox)
    Application.put_env(:helmsman, :backup_sandbox, true)
    on_exit(fn -> Application.put_env(:helmsman, :backup_sandbox, old) end)
    owner = user_fixture()
    workspace = workspace_fixture(owner)
    scope = workspace_scope_fixture(owner, workspace)
    project = project_fixture(scope, %{key: "BOS"})
    task = task_fixture(scope, project.key)
    path = Path.join(System.tmp_dir!(), "backup-#{System.unique_integer([:positive])}.json.gz")
    on_exit(fn -> File.rm(path) end)
    %{scope: scope, workspace: workspace, owner: owner, project: project, task: task, path: path}
  end

  test "export is a portable gzip snapshot and byte-stable on encoding", ctx do
    {:ok, stats} = Backup.export_to_file(ctx.workspace, ctx.path)
    assert stats.counts["tasks"] == 1
    assert byte_size(stats.sha256) == 64
    {:ok, data} = Read.file(ctx.path)
    assert data["tasks"] |> hd() |> Map.fetch!("id") == ctx.task.ident
    assert {:ok, ^data} = Validate.validate(data)
    encoded = Format.encode(data)
    assert Format.encode(Jason.decode!(encoded)) == encoded
  end

  test "merge of the same snapshot leaves domain rows unchanged", ctx do
    {:ok, _} = Backup.export_to_file(ctx.workspace, ctx.path)
    before = Repo.get!(Tasks.Task, ctx.task.id)
    assert {:ok, report} = Backup.import_file(ctx.scope, ctx.path)
    assert report.counts["tasks"].unchanged == 1
    after_task = Repo.get!(Tasks.Task, ctx.task.id)
    assert after_task.updated_at == before.updated_at
    assert after_task.lock_version == before.lock_version

    assert Repo.aggregate(
             from(i in ImportRecord, where: i.workspace_id == ^ctx.workspace.id),
             :count
           ) == 1
  end

  test "replace into a different workspace preserves snapshot fields", ctx do
    {:ok, f1} =
      Feedback.add(ctx.scope, ctx.task.ident, %{kind: :question, content: "What should ship?"})

    {:ok, _} =
      Feedback.revise(ctx.scope, "#{ctx.task.ident}##{f1.seq}", %{
        kind: :question,
        content: "What should ship first?"
      })

    {:ok, _} = Backup.export_to_file(ctx.workspace, ctx.path)
    {:ok, original} = Read.file(ctx.path)
    second = workspace_fixture(ctx.owner)
    scope = workspace_scope_fixture(ctx.owner, second)
    assert {:ok, _} = Backup.import_file(scope, ctx.path, mode: :replace, confirm: second.slug)
    other = ctx.path <> ".second"
    on_exit(fn -> File.rm(other) end)
    assert {:ok, _} = Backup.export_to_file(second, other)
    {:ok, restored} = Read.file(other)

    assert Map.drop(original, ~w(exported_at source workspace)) ==
             Map.drop(restored, ~w(exported_at source workspace))
  end

  test "dry run performs writes but keeps only the audit record", ctx do
    {:ok, _} = Backup.export_to_file(ctx.workspace, ctx.path)
    other = workspace_fixture(ctx.owner)
    scope = workspace_scope_fixture(ctx.owner, other)
    assert {:ok, report} = Backup.import_file(scope, ctx.path, dry_run: true)
    assert report.counts["tasks"].created == 1
    assert Repo.aggregate(from(t in Tasks.Task, where: t.workspace_id == ^other.id), :count) == 0
    assert Repo.one(from(i in ImportRecord, where: i.workspace_id == ^other.id)).dry_run
  end

  test "merge fast-forwards and rejects a fork atomically", ctx do
    {:ok, _} = Backup.export_to_file(ctx.workspace, ctx.path)
    {:ok, old} = Read.file(ctx.path)
    {:ok, _} = Tasks.transition(ctx.scope, ctx.task.ident, :in_progress, %{})
    {:ok, _} = Backup.export_to_file(ctx.workspace, ctx.path)
    other = workspace_fixture(ctx.owner)
    scope = workspace_scope_fixture(ctx.owner, other)
    old_path = ctx.path <> ".old"
    on_exit(fn -> File.rm(old_path) end)
    File.write!(old_path, Format.encode(old))
    assert {:ok, _} = Backup.import_file(scope, old_path)
    assert {:ok, report} = Backup.import_file(scope, ctx.path)
    assert report.counts["tasks"].fast_forwarded == 1
    {:ok, new} = Read.file(ctx.path)

    fork =
      Map.update!(new, "task_events", fn events ->
        List.update_at(events, 0, &Map.put(&1, "comment", "fork"))
      end)

    File.write!(old_path, Format.encode(fork))
    assert {:error, {:diverged, _}} = Backup.import_file(scope, old_path)
    assert Repo.aggregate(from(t in Tasks.Task, where: t.workspace_id == ^other.id), :count) == 1
  end

  test "background export requests coalesce and produce downloadable private files", ctx do
    assert {:ok, record} = Backup.request_export(ctx.scope)
    assert {:ok, same} = Backup.request_export(ctx.scope)
    assert same.id == record.id
    assert :ok = ExportWorker.perform(%Oban.Job{args: %{"id" => record.id}})
    assert {:ok, file} = Backup.export_file(ctx.scope, record.id)
    assert File.exists?(file.path)
    on_exit(fn -> File.rm(file.path) end)
    assert file.filename =~ ".helmsman.json.gz"
  end

  test "failed streamed export removes its partial artifact and settles the job", ctx do
    assert {:ok, record} = Backup.request_export(ctx.scope)

    Process.put(:helmsman_test_hook, fn
      {:export_read, "saved_filters"} -> raise "injected export failure"
      _ -> :ok
    end)

    assert :ok = ExportWorker.perform(%Oban.Job{args: %{"id" => record.id}})
    Process.delete(:helmsman_test_hook)
    failed = Repo.get!(Backup.ExportRecord, record.id)
    assert failed.status == :failed
    assert {:ok, path} = Backup.Files.path(:exports, failed.file)
    refute File.exists?(path)
    assert {:error, :not_found} = Backup.export_file(ctx.scope, record.id)
  end

  test "an imported human is not assignable and can be claimed", ctx do
    source =
      Repo.insert!(%Actors.Actor{workspace_id: ctx.workspace.id, kind: :human, name: "unclaimed"})

    assert {:ok, actors} = Actors.list(ctx.scope)
    assert Enum.find(actors, &(&1.name == source.name)).unclaimed
    assert {:ok, mcp_actors} = ListActors.call(%{}, %{scope: ctx.scope})
    assert Enum.find(mcp_actors, &(&1.name == source.name)).unclaimed

    Repo.update_all(from(t in Tasks.Task, where: t.id == ^ctx.task.id),
      set: [created_by_id: source.id]
    )

    assert {:ok, task} = Tasks.get(ctx.scope, ctx.task.ident)
    assert Tasks.summary(task).created_by.unclaimed

    assert {:ok, assignable} = Actors.list_assignable(ctx.scope)
    refute Enum.any?(assignable, &(&1.id == source.id))
    assert {:error, changeset} = Tasks.update(ctx.scope, ctx.task.ident, %{assignee: source.name})
    assert errors_on(changeset).assignee == ["is not a member"]
    assert {:ok, claim} = Actors.request_claim(ctx.scope, source.name)
    assert {:ok, _} = Actors.decide_claim(ctx.scope, claim.id, :approve)
    refute Repo.get(Actors.Actor, source.id)
  end

  test "replace needs confirmation", ctx do
    assert {:error, :confirmation_required} =
             Backup.import_file(ctx.scope, ctx.path, mode: :replace)
  end
end
