defmodule Helmsman.Backup.ImportSpecTest do
  use Helmsman.DataCase, async: false
  import Helmsman.RunsFixtures
  import Helmsman.TaskSpecsFixtures
  import Helmsman.WorkspacesFixtures
  import Helmsman.ProjectsFixtures
  alias Helmsman.{Backup, Projects, TaskSpecs}
  alias Helmsman.Backup.{Format, Import.Read, Import.Validate}
  alias Helmsman.Projects.Project
  alias Helmsman.TaskSpecs.{Event, Issue, IssueNote, ReviewRequest, Spec, Version}

  setup do
    old = Application.get_env(:helmsman, :backup_sandbox)
    Application.put_env(:helmsman, :backup_sandbox, true)
    on_exit(fn -> Application.put_env(:helmsman, :backup_sandbox, old) end)
    ctx = specs_fixture()
    spec_fixture(ctx.alice_scope, ctx.task.ident)
    target = workspace_fixture(ctx.alice)
    scope = workspace_scope_fixture(ctx.alice, target)

    paths =
      Enum.map(
        1..3,
        &Path.join(
          System.tmp_dir!(),
          "import-spec-#{System.unique_integer([:positive])}-#{&1}.gz"
        )
      )

    on_exit(fn -> Enum.each(paths, &File.rm/1) end)
    Map.merge(ctx, %{target: target, scope: scope, paths: paths})
  end

  defp snapshot(ctx, n) do
    path = Enum.at(ctx.paths, n)
    {:ok, _} = Backup.export_to_file(ctx.workspace, path)
    {:ok, data} = Read.file(path)
    {path, data}
  end

  defp local_spec(ctx), do: Repo.get_by!(Spec, workspace_id: ctx.target.id)
  defp write(ctx, data), do: File.write!(List.last(ctx.paths), Format.encode(data))

  test "events alone fast-forward, older snapshots skip, reopened finalizations survive", ctx do
    {old, _} = snapshot(ctx, 0)
    assert {:ok, _} = Backup.import_file(ctx.scope, old)

    assert {:ok, _} =
             TaskSpecs.finalize(ctx.alice_scope, ctx.task.ident, %{version: 1, wake: false})

    {final, _} = snapshot(ctx, 1)
    # The task can be locally newer while its spec is independently behind.
    {:ok, _} = Helmsman.Tasks.update(ctx.scope, ctx.task.ident, %{title: "Local title"})
    assert {:ok, report} = Backup.import_file(ctx.scope, final)
    assert report.counts["specs"].fast_forwarded == 1
    assert local_spec(ctx).final_version == 1
    assert {:ok, report} = Backup.import_file(ctx.scope, old)
    assert report.counts["specs"].local_newer == 1
    assert {:ok, _} = TaskSpecs.reopen(ctx.alice_scope, ctx.task.ident, %{reason: "Next"})

    assert {:ok, _} =
             TaskSpecs.submit_version(ctx.alice_scope, ctx.task.ident, %{
               base_version: 1,
               files: spec_files(tag: "v2")
             })

    assert {:ok, _} =
             TaskSpecs.finalize(ctx.alice_scope, ctx.task.ident, %{version: 2, wake: false})

    {new, _} = snapshot(ctx, 2)
    assert {:ok, _} = Backup.import_file(ctx.scope, new)
    assert local_spec(ctx).final_version == 2

    assert Repo.all(
             from(e in Event,
               where: e.workspace_id == ^ctx.target.id and e.action == "finalized",
               order_by: e.number,
               select: e.version
             )
           ) == [1, 2]

    before = local_spec(ctx)
    assert {:ok, report} = Backup.import_file(ctx.scope, new)
    assert report.counts["specs"].unchanged == 1
    assert local_spec(ctx) == before
  end

  test "replace roundtrip recomputes validation, notes and leaves pending requests without runs",
       ctx do
    bob_name = human_actor(ctx.workspace, ctx.bob).name
    assert {:ok, _} = TaskSpecs.request_reviews(ctx.alice_scope, ctx.task.ident, [bob_name])

    assert {:ok, _} =
             TaskSpecs.submit_review(ctx.bob_scope, ctx.task.ident, %{
               version: 1,
               verdict: "comment",
               summary: "Review",
               issues: [%{severity: "P3", body: "Discuss"}]
             })

    assert {:ok, _} =
             TaskSpecs.add_note(ctx.alice_scope, ctx.task.ident, "R1.1", %{
               resolution: "accepted",
               body: "Fixed",
               fixed_in_version: 1
             })

    assert {:ok, _} =
             TaskSpecs.add_note(ctx.alice_scope, ctx.task.ident, "R1.1", %{body: "Follow-up"})

    assert {:ok, _} =
             TaskSpecs.request_reviews(ctx.alice_scope, ctx.task.ident, [bob_name, "keel/review"])

    {path, original} = snapshot(ctx, 0)

    assert {:ok, _} =
             Backup.import_file(ctx.scope, path, mode: :replace, confirm: ctx.target.slug)

    assert Repo.get_by!(Issue, workspace_id: ctx.target.id).resolution == :accepted
    assert Repo.get_by!(Issue, workspace_id: ctx.target.id).note_seq == 2
    assert Repo.get_by!(Version, workspace_id: ctx.target.id).valid

    assert Repo.aggregate(
             from(r in Helmsman.Runs.Run, where: r.workspace_id == ^ctx.target.id),
             :count
           ) == 0

    assert Repo.exists?(
             from(r in ReviewRequest,
               where: r.workspace_id == ^ctx.target.id and r.status == :requested
             )
           )

    assert {:ok, _} = Backup.export_to_file(ctx.target, Enum.at(ctx.paths, 1))
    {:ok, restored} = Read.file(Enum.at(ctx.paths, 1))

    assert {:ok, _} =
             Backup.import_file(ctx.alice_scope, path,
               mode: :replace,
               confirm: ctx.workspace.slug
             )

    assert {:ok, _} = Backup.export_to_file(ctx.workspace, List.last(ctx.paths))
    {:ok, same_workspace} = Read.file(List.last(ctx.paths))
    assert Map.delete(original, "exported_at") == Map.delete(same_workspace, "exported_at")

    original =
      Map.update!(
        original,
        "actors",
        &Enum.map(&1, fn a ->
          if a["kind"] == "squad", do: Map.put(a, "disabled", true), else: a
        end)
      )

    assert Map.drop(original, ~w(exported_at source workspace)) ==
             Map.drop(restored, ~w(exported_at source workspace))

    empty =
      original
      |> Map.new(fn {k, v} ->
        {k, if(k in Format.collections() and k != "actors" and k != "projects", do: [], else: v)}
      end)

    write(ctx, empty)

    assert {:ok, _} =
             Backup.import_file(ctx.scope, List.last(ctx.paths),
               mode: :replace,
               confirm: ctx.target.slug
             )

    refute Repo.exists?(from(s in Spec, where: s.workspace_id == ^ctx.target.id))
    refute Repo.exists?(from(n in IssueNote, where: n.workspace_id == ^ctx.target.id))
    refute Repo.exists?(from(v in Version, where: v.workspace_id == ^ctx.target.id))
  end

  test "v1 defaults project policy, preserves local specs, rejects version 3", ctx do
    {path, data} = snapshot(ctx, 0)
    {:ok, _} = Backup.import_file(ctx.scope, path)
    before = local_spec(ctx)

    v1 =
      data
      |> Map.put("version", 1)
      |> Map.drop(Format.spec_collections())
      |> Map.update!("projects", &Enum.map(&1, fn p -> Map.delete(p, "spec_finalize") end))

    assert {:ok, validated} = Validate.validate(v1)
    assert hd(validated["projects"])["spec_finalize"] == "approval"
    write(ctx, v1)
    assert {:ok, _} = Backup.import_file(ctx.scope, List.last(ctx.paths))
    assert local_spec(ctx) == before
    assert {:error, :unsupported_format} = Validate.validate(Map.put(data, "version", 3))
  end

  test "fork and change ID collisions roll back other records", ctx do
    {path, _} = snapshot(ctx, 0)
    {:ok, _} = Backup.import_file(ctx.scope, path)

    {:ok, _} =
      TaskSpecs.submit_version(ctx.scope, ctx.task.ident, %{
        base_version: 1,
        files: spec_files(tag: "local")
      })

    {:ok, _} =
      TaskSpecs.submit_version(ctx.alice_scope, ctx.task.ident, %{
        base_version: 1,
        files: spec_files(tag: "incoming")
      })

    {new, data} = snapshot(ctx, 1)
    before = local_spec(ctx)

    assert {:error, {:diverged, %{sequence: "spec_versions", position: 2}}} =
             Backup.import_file(ctx.scope, new)

    assert local_spec(ctx) == before
    other = workspace_fixture(ctx.alice)
    other_scope = workspace_scope_fixture(ctx.alice, other)
    {:ok, _} = Backup.import_file(other_scope, path)
    # Remove only this task's spec; leave its imported task history unchanged.
    Repo.delete_all(from(s in Spec, where: s.workspace_id == ^other.id))
    local_task = Repo.get_by!(Helmsman.Tasks.Task, workspace_id: other.id, ident: ctx.task.ident)
    conflict = task_fixture(other_scope, ctx.project.key)
    spec_fixture(other_scope, conflict.ident, change_id: hd(data["specs"])["change_id"])
    assert {:error, {:change_id_conflict, _}} = Backup.import_file(other_scope, new)
    refute Repo.exists?(from(s in Spec, where: s.task_id == ^local_task.id))
  end

  test "request closure fast-forwards and cannot regress on an older snapshot", ctx do
    bob_name = human_actor(ctx.workspace, ctx.bob).name
    {:ok, _} = TaskSpecs.request_reviews(ctx.alice_scope, ctx.task.ident, [bob_name])
    {pending, _} = snapshot(ctx, 0)
    {:ok, _} = Backup.import_file(ctx.scope, pending)

    {:ok, _} =
      TaskSpecs.submit_review(ctx.bob_scope, ctx.task.ident, %{
        version: 1,
        verdict: "pass",
        summary: "Good"
      })

    {closed, data} = snapshot(ctx, 1)
    assert {:ok, report} = Backup.import_file(ctx.scope, closed)
    assert report.counts["specs"].fast_forwarded == 1
    assert Repo.get_by!(ReviewRequest, workspace_id: ctx.target.id).status == :submitted
    assert {:ok, report} = Backup.import_file(ctx.scope, pending)
    assert report.counts["specs"].local_newer == 1
    assert Repo.get_by!(ReviewRequest, workspace_id: ctx.target.id).status == :submitted

    invalid =
      Map.update!(data, "spec_review_requests", fn [r] -> [Map.put(r, "status", "requested")] end)

    assert {:error, {:invalid_import, errors}} = Validate.validate(invalid)
    assert Enum.any?(errors, &(&1[:reason] == "spec_state_mismatch"))
  end

  test "proposal author is portable, approval events fast-forward, validation is recomputed",
       ctx do
    {lead_scope, _} = agent_run_scope(ctx.lead, ctx.task, %{squad_id: ctx.squad.id})

    {:ok, %{decision: :proposed}} =
      TaskSpecs.finalize(lead_scope, ctx.task.ident, %{version: 1, summary: "Ready"})

    {pending, data} = snapshot(ctx, 0)
    assert hd(data["specs"])["proposal"]["by"] == ctx.lead.name
    assert {:ok, _} = Backup.import_file(ctx.scope, pending)
    assert local_spec(ctx).status == :pending_approval
    {:ok, _} = TaskSpecs.finalize(ctx.alice_scope, ctx.task.ident, %{version: 1, wake: false})
    {approved, _} = snapshot(ctx, 1)
    assert {:ok, report} = Backup.import_file(ctx.scope, approved)
    assert report.counts["specs"].fast_forwarded == 1
    assert local_spec(ctx).final_version == 1
    # Stored validation is disposable and cannot influence a restored version.
    Repo.update_all(from(v in Version, where: v.workspace_id == ^ctx.workspace.id),
      set: [valid: false, validation: %{}]
    )

    {new, _} = snapshot(ctx, 2)
    other = workspace_fixture(ctx.alice)
    assert {:ok, _} = Backup.import_file(workspace_scope_fixture(ctx.alice, other), new)
    assert Repo.get_by!(Version, workspace_id: other.id).valid
  end

  test "project policy follows updated_at and rename normalizes all spec actor references", ctx do
    {path, _} = snapshot(ctx, 0)
    {:ok, _} = Backup.import_file(ctx.scope, path)
    local_project = Repo.get_by!(Project, workspace_id: ctx.target.id)

    Repo.update_all(from(p in Project, where: p.id == ^local_project.id),
      set: [updated_at: ~N[2025-01-01 00:00:00]]
    )

    assert {:ok, _} = Projects.update(ctx.alice_scope, ctx.project.key, %{spec_finalize: :leader})
    {new, _} = snapshot(ctx, 1)
    assert {:ok, _} = Backup.import_file(ctx.scope, new)
    assert Repo.get!(Project, local_project.id).spec_finalize == :leader

    Repo.update_all(from(p in Project, where: p.id == ^local_project.id),
      set: [spec_finalize: :approval, updated_at: ~N[2030-01-01 00:00:00]]
    )

    assert {:ok, _} = Backup.import_file(ctx.scope, new)
    assert Repo.get!(Project, local_project.id).spec_finalize == :approval
    other = workspace_fixture(ctx.alice)
    scope = workspace_scope_fixture(ctx.alice, other)
    renamed = "imported/author"

    assert {:ok, _} =
             Backup.import_file(scope, new, rename: %{ctx.alice_scope.actor.name => renamed})

    assert {:ok, _} = Backup.export_to_file(other, Enum.at(ctx.paths, 2))
    {:ok, restored} = Read.file(Enum.at(ctx.paths, 2))
    assert hd(restored["spec_versions"])["author"] == renamed
    assert hd(restored["spec_events"])["actor"] == renamed
    assert hd(restored["specs"])["created_by"] == renamed
    assert {:ok, _} = Validate.validate(restored)
  end

  test "dry run rolls back specs and malformed array records report positions", ctx do
    {path, data} = snapshot(ctx, 0)
    assert {:ok, report} = Backup.import_file(ctx.scope, path, dry_run: true)
    assert report.counts["specs"].created == 1
    refute Repo.exists?(from(s in Spec, where: s.workspace_id == ^ctx.target.id))

    for value <- [nil, %{}, 42] do
      assert {:error, {:invalid_import, _}} =
               Validate.validate(Map.put(data, "spec_versions", value))
    end

    assert {:error, {:invalid_import, [%{path: "spec_versions[0]"}]}} =
             Validate.validate(Map.put(data, "spec_versions", [nil]))

    bad =
      Map.update!(data, "spec_versions", fn [r] ->
        [
          Map.put(r, "files", [
            %{"path" => "tasks.md", "content" => String.duplicate("x", 262_145)}
          ])
        ]
      end)

    assert {:error, {:invalid_import, errors}} = Validate.validate(bad)
    assert Enum.any?(errors, &String.starts_with?(&1.path, "spec_versions[0].files"))
  end

  test "invalid histories, fields, references and mutable states are rejected before writes",
       ctx do
    {_path, data} = snapshot(ctx, 0)

    cases = [
      {"spec_versions", "n", 3},
      {"spec_versions", "author", "missing/actor"},
      {"spec_versions", "files", [%{"path" => "../oops", "content" => "x"}]},
      {"spec_versions", "files", [%{"path" => "tasks.md", "content" => <<0>>}]},
      {"specs", "status", "finalized"},
      {"spec_events", "action", "unknown"},
      {"spec_events", "data", %{}},
      {"specs", "latest_version", 5}
    ]

    for {collection, field, value} <- cases do
      invalid =
        Map.update!(data, collection, fn [first | rest] ->
          [Map.put(first, field, value) | rest]
        end)

      assert {:error, {:invalid_import, errors}} = Validate.validate(invalid)
      assert Enum.any?(errors, &String.starts_with?(&1.path, collection))
      write(ctx, invalid)
      assert {:error, {:invalid_import, _}} = Backup.import_file(ctx.scope, List.last(ctx.paths))
      refute Repo.exists?(from(s in Spec, where: s.workspace_id == ^ctx.target.id))
    end
  end
end
