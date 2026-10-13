defmodule Helmsman.Backup.Import.MergeWriteTest do
  use Helmsman.DataCase, async: false
  import Helmsman.DependencyFixtures
  import Helmsman.ProjectsFixtures
  import Helmsman.GitHubFixtures
  alias Helmsman.{Backup, Feedback, Links, Tasks}
  alias Helmsman.Backup.{Format, ImportRecord}
  alias Helmsman.Backup.Import.Read

  setup do
    ctx = dependency_fixture()
    path = Path.join(System.tmp_dir!(), "merge-write-#{System.unique_integer([:positive])}")
    old = Application.get_env(:helmsman, :backup_sandbox)
    Application.put_env(:helmsman, :backup_sandbox, true)

    on_exit(fn ->
      File.rm(path)
      Application.put_env(:helmsman, :backup_sandbox, old)
    end)

    Map.put(ctx, :path, path)
  end

  test "state fast-forward schedules dependency recheck without dispatch or notes", ctx do
    put_assignee!(ctx.web2, ctx.agent.id)
    run = run_with!(ctx, ctx.web2, :deferred, ["assign"])
    {:ok, _} = Backup.export_to_file(ctx.workspace, ctx.path)
    {:ok, data} = Read.file(ctx.path)
    task = Enum.find(data["tasks"], &(&1["id"] == ctx.bos1.ident))
    original_event = Enum.find(data["task_events"], &(&1["task"] == ctx.bos1.ident))
    at = "2026-12-01T00:00:00.000000Z"

    data =
      data
      |> Map.update!("tasks", fn rows ->
        Enum.map(
          rows,
          &if(&1["id"] == task["id"],
            do:
              Map.merge(&1, %{
                "status" => "done",
                "updated_at" => at,
                "assignee" => ctx.agent.name
              }),
            else: &1
          )
        )
      end)
      |> Map.update!(
        "task_events",
        &(&1 ++
            [Map.merge(original_event, %{"n" => 2, "from" => "new", "to" => "done", "at" => at})])
      )

    File.write!(ctx.path, Format.encode(data))

    Repo.delete_all(
      from(j in Oban.Job, where: j.worker == "Helmsman.Dispatch.Workers.ReleaseDependents")
    )

    runs =
      Repo.aggregate(
        from(r in Helmsman.Runs.Run, where: r.workspace_id == ^ctx.workspace.id),
        :count
      )

    notes =
      Repo.aggregate(
        from(f in Feedback.Entry, where: f.workspace_id == ^ctx.workspace.id),
        :count
      )

    assert {:ok, _} = Backup.import_file(ctx.alice_scope, ctx.path)

    assert Repo.exists?(
             from(j in Oban.Job,
               where:
                 j.worker == "Helmsman.Dispatch.Workers.ReleaseDependents" and
                   fragment("(?->>'task_id')::bigint", j.args) == ^ctx.bos1.id
             )
           )

    assert Repo.get!(Helmsman.Runs.Run, run.id).status == :deferred

    assert Repo.aggregate(
             from(r in Helmsman.Runs.Run, where: r.workspace_id == ^ctx.workspace.id),
             :count
           ) == runs

    assert Repo.aggregate(
             from(f in Feedback.Entry, where: f.workspace_id == ^ctx.workspace.id),
             :count
           ) == notes
  end

  test "individually acyclic input which cycles with local links rolls back field edits", ctx do
    {:ok, _} = Backup.export_to_file(ctx.workspace, ctx.path)
    {:ok, data} = Read.file(ctx.path)
    reversed = Map.merge(hd(data["links"]), %{"from" => ctx.bos1.ident, "to" => ctx.web2.ident})

    data =
      data
      |> Map.put("links", [reversed])
      |> Map.update!("tasks", fn rows ->
        Enum.map(
          rows,
          &Map.merge(&1, %{
            "title" => "must roll back",
            "updated_at" => "2026-12-01T00:00:00.000000Z"
          })
        )
      end)

    File.write!(ctx.path, Format.encode(data))
    before = Repo.get!(Tasks.Task, ctx.bos1.id)
    assert {:error, {:cycle, _}} = Backup.import_file(ctx.alice_scope, ctx.path)
    assert Repo.get!(Tasks.Task, ctx.bos1.id) == before

    assert Repo.aggregate(
             from(l in Links.Link, where: l.workspace_id == ^ctx.workspace.id),
             :count
           ) == 1

    assert Repo.one!(from(i in ImportRecord, where: i.workspace_id == ^ctx.workspace.id)).status ==
             :failed
  end

  test "old snapshot never resurrects revised feedback", ctx do
    {:ok, feedback} = Feedback.add(ctx.alice_scope, ctx.bos1.ident, %{content: "original"})
    {:ok, _} = Backup.export_to_file(ctx.workspace, ctx.path)

    {:ok, _} =
      Feedback.revise(ctx.alice_scope, "#{ctx.bos1.ident}##{feedback.seq}", %{content: "revised"})

    assert {:ok, report} = Backup.import_file(ctx.alice_scope, ctx.path)
    assert report.counts["tasks"].local_newer == 1
    assert Repo.get!(Feedback.Entry, feedback.id).status == :superseded
    assert Repo.get!(Tasks.Task, ctx.bos1.id).feedback_count == 1
  end

  test "replace preserves bindings, empty local projects and sequence high-water mark", ctx do
    Repo.update_all(from(p in Helmsman.Projects.Project, where: p.id == ^ctx.project.id),
      set: [task_seq: 20, merge_policy: "manual"]
    )

    repository = repository_fixture(installation_fixture(ctx.workspace))

    Repo.update_all(from(p in Helmsman.Projects.Project, where: p.id == ^ctx.project.id),
      set: [repository_id: repository.id]
    )

    extra = project_fixture(ctx.alice_scope)
    {:ok, _} = Backup.export_to_file(ctx.workspace, ctx.path)
    {:ok, data} = Read.file(ctx.path)

    data =
      Map.update!(data, "projects", fn rows ->
        rows |> Enum.reject(&(&1["key"] == extra.key)) |> Enum.map(&Map.put(&1, "task_seq", 2))
      end)

    File.write!(ctx.path, Format.encode(data))
    before = Repo.get!(Helmsman.Projects.Project, ctx.project.id)

    assert {:ok, _} =
             Backup.import_file(ctx.alice_scope, ctx.path,
               mode: :replace,
               confirm: ctx.workspace.slug
             )

    after_project = Repo.get!(Helmsman.Projects.Project, ctx.project.id)
    assert after_project.task_seq == 20
    assert after_project.repository_id == before.repository_id
    assert after_project.local_repository_id == before.local_repository_id
    assert after_project.merge_policy == before.merge_policy
    assert Repo.get!(Helmsman.Projects.Project, extra.id) == extra
    next = task_fixture(ctx.alice_scope, ctx.project.key)
    assert next.seq == 21
  end
end
