defmodule Helmsman.Backup.ExportSpecTest do
  use Helmsman.DataCase, async: false
  import Helmsman.TaskSpecsFixtures
  alias Helmsman.{Backup, TaskSpecs}
  alias Helmsman.Backup.{Format, Import.Read, Import.Validate}

  setup do
    old = Application.get_env(:helmsman, :backup_sandbox)
    Application.put_env(:helmsman, :backup_sandbox, true)
    on_exit(fn -> Application.put_env(:helmsman, :backup_sandbox, old) end)
    ctx = specs_fixture()
    path = Path.join(System.tmp_dir!(), "export-spec-#{System.unique_integer([:positive])}.gz")
    on_exit(fn -> File.rm(path) end)
    Map.put(ctx, :path, path)
  end

  test "v2 has complete immutable histories, portable references and deterministic order", ctx do
    spec_fixture(ctx.alice_scope, ctx.task.ident, versions: 2)
    {review_scope, _} = agent_run_scope(ctx.review, ctx.task)

    assert {:ok, _} =
             TaskSpecs.submit_review(review_scope, ctx.task.ident, %{
               version: 2,
               verdict: "comment",
               summary: "Check",
               issues: [%{severity: "P3", file: "tasks.md", line: 1, body: "Discuss"}]
             })

    assert {:ok, _} =
             TaskSpecs.add_note(ctx.alice_scope, ctx.task.ident, "R1.1", %{body: "Reply"})

    assert {:ok, _} =
             TaskSpecs.add_note(ctx.alice_scope, ctx.task.ident, "R1.1", %{
               resolution: "accepted",
               body: "Fixed",
               fixed_in_version: 2
             })

    assert {:ok, _} =
             TaskSpecs.finalize(ctx.alice_scope, ctx.task.ident, %{version: 2, wake: false})

    assert {:ok, stats} = Backup.export_to_file(ctx.workspace, ctx.path)
    assert stats.counts["spec_versions"] == 2
    {:ok, first} = Read.file(ctx.path)
    assert first["version"] == 2
    assert [%{"final_version" => 2, "status" => "finalized"}] = first["specs"]
    assert Enum.map(first["spec_versions"], & &1["n"]) == [1, 2]

    for version <- first["spec_versions"] do
      assert Enum.sort(Map.keys(version)) == Format.fields()["spec_versions"]
      assert version["files"] == Enum.sort_by(version["files"], & &1["path"])
    end

    assert length(first["spec_issue_notes"]) == 2
    refute Map.has_key?(hd(first["spec_issues"]), "resolution")
    assert Enum.any?(first["spec_events"], &(&1["action"] == "finalized" and &1["version"] == 2))

    for key <- Format.spec_collections(), row <- first[key] do
      assert Enum.sort(Map.keys(row)) == Format.fields()[key]
    end

    assert {:ok, _} = Backup.export_to_file(ctx.workspace, ctx.path)
    {:ok, second} = Read.file(ctx.path)
    assert Map.delete(first, "exported_at") == Map.delete(second, "exported_at")
    assert {:ok, ^first} = Validate.validate(first)
  end
end
