defmodule Helmsman.Backup.HistoryTest do
  use Helmsman.DataCase, async: false
  import Helmsman.AccountsFixtures
  import Helmsman.WorkspacesFixtures
  import Helmsman.ProjectsFixtures
  alias Helmsman.{Backup, Tasks}
  alias Helmsman.Backup.Format
  alias Helmsman.Backup.Import.{Read, Validate}

  setup do
    user = user_fixture()
    workspace = workspace_fixture(user)
    scope = workspace_scope_fixture(user, workspace)
    project = project_fixture(scope)
    task = task_fixture(scope, project.key)

    path =
      Path.join(System.tmp_dir!(), "history-roundtrip-#{System.unique_integer([:positive])}.gz")

    old = Application.get_env(:helmsman, :backup_sandbox)
    Application.put_env(:helmsman, :backup_sandbox, true)

    on_exit(fn ->
      File.rm(path)
      Application.put_env(:helmsman, :backup_sandbox, old)
    end)

    %{user: user, workspace: workspace, scope: scope, task: task, project: project, path: path}
  end

  test "40, 41 and 64 hex commits from normal transitions roundtrip; 65 rejects", ctx do
    for length <- [40, 41, 64] do
      task = task_fixture(ctx.scope, ctx.project.key)

      assert {:ok, _} =
               Tasks.transition(ctx.scope, task.ident, :in_progress,
                 commits: [String.duplicate("a", length)]
               )
    end

    assert {:ok, _} = Backup.export_to_file(ctx.workspace, ctx.path)
    assert {:ok, data} = Read.file(ctx.path)
    assert {:ok, _} = Validate.validate(data)
    target = workspace_fixture(ctx.user)
    scope = workspace_scope_fixture(ctx.user, target)
    assert {:ok, _} = Backup.import_file(scope, ctx.path, mode: :replace, confirm: target.slug)
    assert {:ok, _} = Backup.export_to_file(target, ctx.path)
    assert {:ok, restored} = Read.file(ctx.path)
    assert restored["task_events"] == data["task_events"]

    invalid =
      Map.update!(
        data,
        "task_events",
        &List.update_at(&1, 0, fn event ->
          Map.put(event, "commits", [String.duplicate("a", 65)])
        end)
      )

    File.write!(ctx.path, Format.encode(invalid))
    assert {:error, {:invalid_import, errors}} = Backup.import_file(scope, ctx.path)
    assert Enum.any?(errors, &(&1.path == "task_events[0].commits"))
    assert Repo.aggregate(from(t in Tasks.Task, where: t.workspace_id == ^target.id), :count) == 4
  end

  test "n-ordered decreasing timestamps reject before writes; equal timestamps roundtrip", ctx do
    {:ok, _} = Tasks.transition(ctx.scope, ctx.task.ident, :in_progress, %{})
    {:ok, _} = Backup.export_to_file(ctx.workspace, ctx.path)
    {:ok, data} = Read.file(ctx.path)
    [first, second] = data["task_events"]

    invalid =
      Map.put(data, "task_events", [
        Map.put(first, "at", "2026-02-02T00:00:00.000000Z"),
        Map.put(second, "at", "2026-02-01T00:00:00.000000Z")
      ])

    File.write!(ctx.path, Format.encode(invalid))
    target = workspace_fixture(ctx.user)
    scope = workspace_scope_fixture(ctx.user, target)
    assert {:error, {:invalid_import, errors}} = Backup.import_file(scope, ctx.path)

    assert errors == [
             %{
               path: "task_events[1].at",
               message: "must not be earlier than the previous event of the same task"
             }
           ]

    assert Repo.aggregate(from(t in Tasks.Task, where: t.workspace_id == ^target.id), :count) == 0

    prefix =
      invalid
      |> Map.put("task_events", [hd(invalid["task_events"])])
      |> Map.update!("tasks", &Enum.map(&1, fn task -> Map.put(task, "status", "new") end))

    File.write!(ctx.path, Format.encode(prefix))
    assert {:ok, _} = Backup.import_file(scope, ctx.path)
    before = Repo.all(from(t in Tasks.Task, where: t.workspace_id == ^target.id))
    File.write!(ctx.path, Format.encode(invalid))
    assert {:error, {:invalid_import, ^errors}} = Backup.import_file(scope, ctx.path)
    assert Repo.all(from(t in Tasks.Task, where: t.workspace_id == ^target.id)) == before

    equal =
      Map.update!(
        data,
        "task_events",
        &Enum.map(
          &1,
          fn event -> Map.put(event, "at", "2026-02-01T00:00:00.000000Z") end
        )
      )

    File.write!(ctx.path, Format.encode(equal))
    assert {:ok, _} = Backup.import_file(scope, ctx.path, mode: :replace, confirm: target.slug)
    assert {:ok, _} = Backup.export_to_file(target, ctx.path)
    assert {:ok, restored} = Read.file(ctx.path)
    assert restored["task_events"] == equal["task_events"]
    assert {:ok, _} = Validate.validate(restored)

    before = Repo.all(from(t in Tasks.Task, where: t.workspace_id == ^target.id))
    File.write!(ctx.path, Format.encode(invalid))
    assert {:error, {:invalid_import, errors}} = Backup.import_file(scope, ctx.path)
    assert Enum.any?(errors, &(&1.path == "task_events[1].at"))
    assert Repo.all(from(t in Tasks.Task, where: t.workspace_id == ^target.id)) == before
  end
end
