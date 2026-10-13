defmodule Helmsman.Backup.FiltersTest do
  use Helmsman.DataCase, async: false
  import Helmsman.AccountsFixtures
  import Helmsman.WorkspacesFixtures
  alias Helmsman.{Backup, Filters}
  alias Helmsman.Backup.{Format, ImportRecord}
  alias Helmsman.Backup.Import.Read
  alias Helmsman.Filters.SavedFilter

  setup do
    user = user_fixture()
    workspace = workspace_fixture(user)
    scope = workspace_scope_fixture(user, workspace)
    path = Path.join(System.tmp_dir!(), "backup-filters-#{System.unique_integer([:positive])}")
    old = Application.get_env(:helmsman, :backup_sandbox)
    Application.put_env(:helmsman, :backup_sandbox, true)

    on_exit(fn ->
      File.rm(path)
      Application.put_env(:helmsman, :backup_sandbox, old)
    end)

    {:ok, _} = Backup.export_to_file(workspace, path)
    {:ok, data} = Read.file(path)
    %{scope: scope, path: path, data: data}
  end

  defp filter(name, bql, owner), do: %{"name" => name, "bql" => bql, "owner" => owner}

  test "citext name and suffix variants share the import conflict keys", ctx do
    {:ok, _} = Filters.create(ctx.scope, %{name: "triage", bql: "status = new"})
    {:ok, _} = Filters.create(ctx.scope, %{name: "TRIAGE (IMPORTED)", bql: "status = new"})
    project = Helmsman.ProjectsFixtures.project_fixture(ctx.scope)
    task = Helmsman.ProjectsFixtures.task_fixture(ctx.scope, project.key)
    {:ok, _} = Backup.export_to_file(ctx.scope.workspace, ctx.path)
    {:ok, data} = Read.file(ctx.path)
    incoming = [filter("TRIAGE", "status = new", ctx.scope.actor.name)]
    File.write!(ctx.path, Format.encode(Map.put(data, "saved_filters", incoming)))
    assert {:ok, report} = Backup.import_file(ctx.scope, ctx.path)
    assert report.counts["saved_filters"].unchanged == 1
    incoming = [filter("TRIAGE", "status = done", ctx.scope.actor.name)]
    File.write!(ctx.path, Format.encode(Map.put(data, "saved_filters", incoming)))
    assert {:ok, report} = Backup.import_file(ctx.scope, ctx.path)
    assert report.counts["saved_filters"].created == 1
    assert Repo.exists?(from(f in SavedFilter, where: f.name == "TRIAGE (imported 2)"))
    assert Repo.get!(Helmsman.Tasks.Task, task.id).title == task.title
  end

  test "only shared filters export; import uses importing owner and deterministic conflict suffixes",
       ctx do
    {:ok, _} = Filters.create(ctx.scope, %{name: "private", bql: "status = new"})

    {:ok, _} =
      Filters.create(ctx.scope, %{name: "triage", bql: "status = new", visibility: :workspace})

    {:ok, _} = Backup.export_to_file(ctx.scope.workspace, ctx.path)
    {:ok, data} = Read.file(ctx.path)
    assert Enum.map(data["saved_filters"], & &1["name"]) == ["triage"]

    incoming = [
      filter("triage", "status = new", ctx.scope.actor.name),
      filter("queue", "status = done", ctx.scope.actor.name)
    ]

    {:ok, _} = Filters.create(ctx.scope, %{name: "queue", bql: "status = new"})
    {:ok, _} = Filters.create(ctx.scope, %{name: "queue (imported)", bql: "status = new"})
    File.write!(ctx.path, Format.encode(Map.put(ctx.data, "saved_filters", incoming)))
    assert {:ok, report} = Backup.import_file(ctx.scope, ctx.path)
    assert report.counts["saved_filters"].created == 1
    assert report.counts["saved_filters"].unchanged == 1

    assert Repo.one!(from(f in SavedFilter, where: f.name == "queue (imported 2)")).visibility ==
             :workspace
  end

  test "invalid BQL and filters beyond the per-owner limit warn without failing tasks", ctx do
    incoming = [filter("bad", "status = ???", ctx.scope.actor.name)]
    File.write!(ctx.path, Format.encode(Map.put(ctx.data, "saved_filters", incoming)))
    assert {:ok, report} = Backup.import_file(ctx.scope, ctx.path)
    assert length(report.warnings) == 1
    now = DateTime.utc_now()

    rows =
      Enum.map(1..100, fn n ->
        %{
          workspace_id: ctx.scope.workspace.id,
          owner_id: ctx.scope.user.id,
          name: "filter #{n}",
          bql: "status = new",
          visibility: :private,
          inserted_at: now,
          updated_at: now
        }
      end)

    Repo.insert_all(SavedFilter, rows)

    File.write!(
      ctx.path,
      Format.encode(
        Map.put(ctx.data, "saved_filters", [filter("extra", "status = new", ctx.scope.actor.name)])
      )
    )

    assert {:ok, report} = Backup.import_file(ctx.scope, ctx.path)
    assert length(report.warnings) == 1
    assert Repo.aggregate(SavedFilter, :count) == 100

    assert Repo.aggregate(
             from(i in ImportRecord, where: i.workspace_id == ^ctx.scope.workspace.id),
             :count
           ) == 2

    File.write!(
      ctx.path,
      Format.encode(
        Map.put(ctx.data, "saved_filters", [
          filter("filter 1", "status = new", ctx.scope.actor.name)
        ])
      )
    )

    assert {:ok, report} = Backup.import_file(ctx.scope, ctx.path)
    assert report.counts["saved_filters"].unchanged == 1
    assert report.warnings == []
  end

  test "long conflict names truncate the base and stay within eighty characters", ctx do
    base = String.duplicate("a", 80)
    {:ok, _} = Filters.create(ctx.scope, %{name: base, bql: "status = new"})

    File.write!(
      ctx.path,
      Format.encode(
        Map.put(ctx.data, "saved_filters", [filter(base, "status = done", ctx.scope.actor.name)])
      )
    )

    assert {:ok, _} = Backup.import_file(ctx.scope, ctx.path)

    assert Repo.exists?(
             from(f in SavedFilter,
               where: f.name == ^(String.duplicate("a", 69) <> " (imported)")
             )
           )
  end
end
