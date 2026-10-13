defmodule Helmsman.Backup.RoundtripTest do
  use Helmsman.DataCase, async: false
  import Helmsman.RunsFixtures
  import Helmsman.SquadsFixtures
  import Helmsman.WorkspacesFixtures
  import Helmsman.ProjectsFixtures
  alias Helmsman.{Actors, Backup, Events, Feedback, Filters, Links, Tasks}
  alias Helmsman.Backup.Format
  alias Helmsman.Backup.Import.Read

  setup do
    old = Application.get_env(:helmsman, :backup_sandbox)
    Application.put_env(:helmsman, :backup_sandbox, true)
    on_exit(fn -> Application.put_env(:helmsman, :backup_sandbox, old) end)
    ctx = dispatch_fixture()

    paths =
      Enum.map(1..2, fn n ->
        Path.join(System.tmp_dir!(), "roundtrip-#{System.unique_integer([:positive])}-#{n}.gz")
      end)

    on_exit(fn -> Enum.each(paths, &File.rm/1) end)
    Map.put(ctx, :paths, paths)
  end

  test "full domain fields survive replace and repeated merge is idle", ctx do
    scope = ctx.alice_scope
    {:ok, external} = Actors.identify(scope, %{name: "disabled/external"})

    Repo.update_all(from(a in Actors.Actor, where: a.id == ^external.id),
      set: [disabled_at: DateTime.utc_now(:second)]
    )

    squad = squad_fixture(scope, %{name: "historical-team"})
    squad_actor = agent_actor(ctx.workspace, squad.name)

    Repo.update_all(from(a in Actors.Actor, where: a.id == ^squad_actor.id),
      set: [disabled_at: DateTime.utc_now(:second)]
    )

    epic = task_fixture(scope, ctx.project.key, %{kind: :epic})

    task =
      task_fixture(scope, ctx.project.key, %{
        epic: epic.ident,
        title: "Unicode 你好",
        description: "Markdown **body**",
        labels: ["z", "a"]
      })

    other = task_fixture(scope, ctx.project.key)
    {:ok, f} = Feedback.add(scope, task.ident, %{kind: :question, content: "Question"})
    {:ok, _} = Feedback.revise(scope, "#{task.ident}##{f.seq}", %{content: "Question revised"})
    {:ok, answer} = Feedback.add(scope, task.ident, %{kind: :answer, content: "Answer"})

    Repo.update_all(from(f in Feedback.Entry, where: f.id == ^answer.id),
      set: [mentions: [scope.actor.id, external.id], fallback: true]
    )

    {:ok, _} = Links.add(scope, other.ident, task.ident, :depends_on)
    {:ok, _} = Links.add(scope, task.ident, epic.ident, :replaces)

    {:ok, _} =
      Filters.create(scope, %{name: "shared", bql: "status = new", visibility: :workspace})

    {:ok, _} = Filters.create(scope, %{name: "private", bql: "status = done"})

    Repo.update_all(from(t in Tasks.Task, where: t.id == ^task.id),
      set: [assignee_id: squad_actor.id]
    )

    Repo.update_all(from(e in Tasks.TaskEvent, where: e.task_id == ^task.id),
      set: [
        assignee_side_ids: [squad_actor.id, scope.actor.id],
        verified_sha: String.duplicate("a", 40),
        comment: "Synthetic event comment",
        commits: [String.duplicate("b", 40)],
        tests: %{"command" => "mix test", "passed" => true, "summary" => "synthetic"},
        auto: true,
        auto_reason: :ci_failed,
        feedback_id: answer.id
      ]
    )

    Repo.query!("UPDATE projects SET archived_at=$2,updated_at=$2 WHERE id=$1", [
      ctx.project.id,
      ~N[2026-01-01 00:00:00.123456]
    ])

    [first, second] = ctx.paths
    assert {:ok, _} = Backup.export_to_file(ctx.workspace, first)
    {:ok, source} = Read.file(first)
    target = workspace_fixture(ctx.alice)
    target_scope = workspace_scope_fixture(ctx.alice, target)

    assert {:ok, _} =
             Backup.import_file(target_scope, first, mode: :replace, confirm: target.slug)

    assert {:ok, _} = Backup.export_to_file(target, second)
    {:ok, restored} = Read.file(second)

    assert Format.encode(Map.drop(source, ~w(exported_at workspace source))) ==
             Format.encode(Map.drop(restored, ~w(exported_at workspace source)))

    before = Repo.all(from(t in Tasks.Task, where: t.workspace_id == ^target.id, order_by: t.id))
    Events.subscribe(Events.topic(:workspace, target.id))
    assert {:ok, report} = Backup.import_file(target_scope, second)
    assert report.counts["tasks"].unchanged == 3
    assert report.counts["feedback"].unchanged == 3
    assert report.counts["task_events"].unchanged == length(restored["task_events"])
    assert report.counts["projects"].unchanged == 1
    assert report.counts["links"].unchanged == 2
    assert report.counts["saved_filters"].unchanged == 1

    assert Enum.all?(report.counts, fn {_, count} ->
             count.created == 0 and count.fast_forwarded == 0 and count.local_newer == 0
           end)

    assert Repo.all(from(t in Tasks.Task, where: t.workspace_id == ^target.id, order_by: t.id)) ==
             before

    refute_receive {:task_updated, _}, 50

    assert Repo.aggregate(
             from(r in Helmsman.Runs.Run, where: r.workspace_id == ^target.id),
             :count
           ) == 0

    assert Repo.aggregate(
             from(f in Feedback.Entry, where: f.workspace_id == ^target.id and f.dispatch != ^[]),
             :count
           ) == 0
  end

  test "newly imported active squad changes only disabled to true", ctx do
    squad_fixture(ctx.alice_scope, %{name: "active-team"})
    [first, second] = ctx.paths
    {:ok, _} = Backup.export_to_file(ctx.workspace, first)
    {:ok, original} = Read.file(first)
    target = workspace_fixture(ctx.alice)
    scope = workspace_scope_fixture(ctx.alice, target)
    {:ok, _} = Backup.import_file(scope, first)
    {:ok, _} = Backup.export_to_file(target, second)
    {:ok, restored} = Read.file(second)

    expected =
      original
      |> Map.drop(~w(exported_at source workspace))
      |> Map.update!("actors", fn actors ->
        Enum.map(actors, fn actor ->
          if actor["kind"] == "squad", do: Map.put(actor, "disabled", true), else: actor
        end)
      end)

    assert Format.encode(expected) ==
             Format.encode(Map.drop(restored, ~w(exported_at source workspace)))
  end
end
