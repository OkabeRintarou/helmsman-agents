defmodule Helmsman.TaskSpecs.ArchiveTest do
  # add-spec-workflow 3.2: task-specs 「OpenSpec 目录的导出与导入」 (decision 18).
  use Helmsman.DataCase, async: true

  import Helmsman.ProjectsFixtures
  import Helmsman.RunsFixtures
  import Helmsman.TaskSpecsFixtures

  alias Helmsman.TaskSpecs
  alias Helmsman.TaskSpecs.Archive

  setup do
    ctx = specs_fixture()
    Map.put(ctx, :ident, ctx.task.ident)
  end

  defp export!(ctx, opts) do
    {:ok, archive} = TaskSpecs.export_archive(ctx.alice_scope, ctx.ident, opts)
    archive
  end

  defp entries(%{content_type: "application/gzip", body: body}) do
    {:ok, files} = :erl_tar.extract({:binary, :zlib.gunzip(body)}, [:memory])
    Map.new(files, fn {name, content} -> {List.to_string(name), content} end)
  end

  defp entries(%{content_type: "application/zip", body: body}) do
    {:ok, files} = :zip.unzip(body, [:memory])
    Map.new(files, fn {name, content} -> {List.to_string(name), content} end)
  end

  defp import(ctx, binary, opts),
    do: TaskSpecs.import_archive(ctx.alice_scope, ctx.ident, binary, opts)

  defp latest(ctx) do
    {:ok, summary} = TaskSpecs.summary(ctx.alice_scope, ctx.ident)
    summary && summary.latest_version
  end

  # A ustar archive written by hand, so that it can hold what no archiver
  # of ours would write: `[{name, content, type, link}]`.
  defp tar(entries) do
    blocks =
      for {name, content, type, link} <- entries do
        padding = rem(512 - rem(byte_size(content), 512), 512)
        [header(name, byte_size(content), type, link), content, :binary.copy(<<0>>, padding)]
      end

    :zlib.gzip(IO.iodata_to_binary([blocks, :binary.copy(<<0>>, 1024)]))
  end

  defp header(name, size, type, link) do
    header =
      IO.iodata_to_binary([
        pad(name, 100),
        octal(0o644, 8),
        octal(0, 8),
        octal(0, 8),
        octal(size, 12),
        octal(0, 12),
        String.duplicate(" ", 8),
        type,
        pad(link, 100),
        "ustar\0",
        "00",
        pad("", 32),
        pad("", 32),
        octal(0, 8),
        octal(0, 8),
        pad("", 155),
        pad("", 12)
      ])

    sum = header |> :binary.bin_to_list() |> Enum.sum()
    <<before::binary-148, _blank::binary-8, rest::binary>> = header
    before <> String.pad_leading(Integer.to_string(sum, 8), 6, "0") <> <<0, ?\s>> <> rest
  end

  defp pad(text, width), do: text <> :binary.copy(<<0>>, width - byte_size(text))
  defp octal(n, width), do: String.pad_leading(Integer.to_string(n, 8), width - 1, "0") <> <<0>>

  defp file(name, content), do: {name, content, "0", ""}

  defp change_dir(prefix, files \\ spec_files()),
    do: tar(for {path, content} <- files, do: file(prefix <> path, content))

  describe "export" do
    test "the version's files and .openspec.yaml below change_id, identical twice", ctx do
      spec_fixture(ctx.alice_scope, ctx.ident, versions: 2, change_id: "add-settings-page")

      for format <- ["tar.gz", "zip"] do
        archive = export!(ctx, format: format)
        assert archive.filename == "add-settings-page-v2.#{format}"
        assert archive == export!(ctx, format: format)

        files = entries(archive)

        assert Map.keys(files) == [
                 "add-settings-page/.openspec.yaml",
                 "add-settings-page/proposal.md",
                 "add-settings-page/specs/settings/spec.md",
                 "add-settings-page/tasks.md"
               ]

        assert files["add-settings-page/proposal.md"] == spec_files(tag: "v2")["proposal.md"]
        {:ok, %{versions: [first | _]}} = TaskSpecs.get(ctx.alice_scope, ctx.ident)

        assert files["add-settings-page/.openspec.yaml"] ==
                 "schema: spec-driven\ncreated: #{Date.to_iso8601(DateTime.to_date(first.at))}\n"
      end

      assert export!(ctx, version: 1).filename == "add-settings-page-v1.tar.gz"
      assert entries(export!(ctx, version: 1))["add-settings-page/proposal.md"] =~ "lost. \n"
    end

    test "with reviews: reviews/spec-review-<n>.md", ctx do
      spec_fixture(ctx.alice_scope, ctx.ident, change_id: "add-settings-page")
      {review, _run} = agent_run_scope(ctx.qa, ctx.task)

      {:ok, %{review: 1}} =
        TaskSpecs.submit_review(review, ctx.ident, %{
          version: 1,
          verdict: "fail",
          summary: "Saving is unclear.",
          issues: [
            %{
              severity: "P1",
              file: "specs/settings/spec.md",
              line: 4,
              anchor: "Save",
              body: "Where is it stored?",
              suggestion: "Name the store."
            },
            %{severity: "P3", body: "Typo."}
          ]
        })

      {:ok, _} =
        TaskSpecs.add_note(ctx.alice_scope, ctx.ident, "R1.1", %{
          resolution: "disputed",
          body: "It is stored\nin the database."
        })

      files = entries(export!(ctx, reviews: true))
      alice = human_actor(ctx.workspace, ctx.alice).name

      assert files["add-settings-page/reviews/spec-review-1.md"] == """
             # Spec review R1 — version 1

             Reviewer: keel/qa
             Verdict: fail

             Saving is unclear.

             ## R1.1 [P1] specs/settings/spec.md:4 Save

             Status: disputed

             Where is it stored?

             Suggestion: Name the store.

             - #{alice} (disputed): It is stored
               in the database.

             ## R1.2 [P3]

             Status: open

             Typo.
             """

      refute Map.has_key?(entries(export!(ctx, [])), "add-settings-page/reviews/spec-review-1.md")
    end

    test "no version, unknown version, format and permissions", ctx do
      assert {:error, {:spec, :not_found, _}} =
               TaskSpecs.export_archive(ctx.alice_scope, ctx.ident)

      spec_fixture(ctx.alice_scope, ctx.ident, versions: 0)
      assert {:error, {:spec, :no_version}} = TaskSpecs.export_archive(ctx.alice_scope, ctx.ident)
      spec_fixture(ctx.alice_scope, ctx.ident)

      assert {:error, {:spec, :version_not_found, 9}} =
               TaskSpecs.export_archive(ctx.alice_scope, ctx.ident, version: 9)

      assert {:error, {:spec, :invalid_params, %{field: :format}}} =
               TaskSpecs.export_archive(ctx.alice_scope, ctx.ident, format: "rar")

      assert {:ok, _} = TaskSpecs.export_archive(ctx.bob_scope, ctx.ident)
    end
  end

  describe "import" do
    test "export then import is no_changes, for both formats", ctx do
      spec_fixture(ctx.alice_scope, ctx.ident, versions: 2)

      for format <- ["tar.gz", "zip"] do
        archive = export!(ctx, format: format, reviews: true)

        assert {:error, {:spec, :no_changes}} =
                 import(ctx, archive.body, base_version: 2, note: "again")
      end

      assert latest(ctx) == 2
    end

    test "a directory of an openspec repository: three files, no warnings", ctx do
      files = Map.put(spec_files(), "reviews/spec-review-1.md", "# Spec review R1\n")
      archive = change_dir("openspec/changes/add-x/", files)

      assert {:ok, %{version: 1, warnings: [], files: listed, validation: %{valid: true}}} =
               import(ctx, archive, base_version: 0, note: "from the repo")

      assert Enum.map(listed, & &1.path) == ["proposal.md", "specs/settings/spec.md", "tasks.md"]
      {:ok, spec} = TaskSpecs.get(ctx.alice_scope, ctx.ident)
      assert spec.spec.change_id == "add-x"
      assert [%{note: "from the repo"}] = spec.versions
    end

    test "the imported version replaces every file; other paths are warnings", ctx do
      spec_fixture(ctx.alice_scope, ctx.ident,
        files: Map.put(spec_files(), "design.md", "## Context\n\nOld.\n"),
        change_id: "add-settings-page"
      )

      files = Map.put(spec_files(tag: "new"), "notes.txt", "scratch")

      archive =
        tar([
          file("x/.openspec.yaml", "schema: spec-driven\n")
          | for({p, c} <- files, do: file("x/" <> p, c))
        ])

      assert {:ok, %{version: 2, warnings: ["notes.txt"]}} =
               import(ctx, archive, base_version: 1)

      {:ok, %{version: version, spec: spec}} = TaskSpecs.get(ctx.alice_scope, ctx.ident)

      assert Enum.map(version.files, & &1.path) == [
               "proposal.md",
               "specs/settings/spec.md",
               "tasks.md"
             ]

      assert spec.change_id == "add-settings-page"
    end

    test "a single file below its directory keeps the specs/ path", ctx do
      content = spec_files()["specs/settings/spec.md"]

      assert {:ok, %{version: 1, files: [%{path: "specs/settings/spec.md"}]}} =
               import(ctx, tar([file("add-y/specs/settings/spec.md", content)]), base_version: 0)

      {:ok, %{spec: %{change_id: "add-y"}}} = TaskSpecs.get(ctx.alice_scope, ctx.ident)
    end

    test "the directory name names an empty spec; a taken or bad one is not used", ctx do
      spec_fixture(ctx.alice_scope, ctx.ident, versions: 0)
      assert {:ok, %{version: 1}} = import(ctx, change_dir("add-z/"), base_version: 0)
      {:ok, %{spec: %{change_id: "add-z"}}} = TaskSpecs.get(ctx.alice_scope, ctx.ident)

      other = task_fixture(ctx.alice_scope, ctx.project.key)
      ident = String.downcase(other.ident)

      assert {:ok, %{version: 1}} =
               TaskSpecs.import_archive(ctx.alice_scope, other.ident, change_dir("add-z/"),
                 base_version: 0
               )

      {:ok, %{spec: %{change_id: ^ident}}} = TaskSpecs.get(ctx.alice_scope, other.ident)

      third = task_fixture(ctx.alice_scope, ctx.project.key)

      {:ok, _} =
        TaskSpecs.import_archive(ctx.alice_scope, third.ident, change_dir("Bad_Name/"),
          base_version: 0
        )

      assert {:ok, %{spec: %{change_id: change_id}}} = TaskSpecs.get(ctx.alice_scope, third.ident)
      assert change_id == String.downcase(third.ident)
    end

    test "a later version keeps change_id", ctx do
      spec_fixture(ctx.alice_scope, ctx.ident, change_id: "add-settings-page")

      assert {:ok, %{version: 2}} =
               import(ctx, change_dir("add-other/", spec_files(tag: "2")), base_version: 1)

      {:ok, %{spec: %{change_id: "add-settings-page"}}} =
        TaskSpecs.get(ctx.alice_scope, ctx.ident)
    end

    test "dry run: the result and the diff, without writing", ctx do
      assert {:ok, preview} = import(ctx, change_dir("add-x/"), base_version: 0, dry_run: true)

      assert %{
               dry_run: true,
               version: nil,
               base_version: 0,
               change_id: "add-x",
               warnings: [],
               validation: %{valid: true},
               diff: %{from: 0, to: nil, truncated: false, files: diffed}
             } = preview

      assert Enum.map(diffed, &{&1.path, &1.change}) == [
               {"proposal.md", :added},
               {"specs/settings/spec.md", :added},
               {"tasks.md", :added}
             ]

      assert latest(ctx) == nil

      spec_fixture(ctx.alice_scope, ctx.ident)

      assert {:ok, %{change_id: nil, diff: %{files: diffed}}} =
               import(ctx, change_dir("add-x/", spec_files(tag: "2")),
                 base_version: 1,
                 dry_run: true
               )

      assert Enum.all?(diffed, &(&1.change == :modified))
      assert latest(ctx) == 1
    end

    test "rules of submit_version: stale, closed, permissions", ctx do
      spec_fixture(ctx.alice_scope, ctx.ident, versions: 2)
      archive = change_dir("add-x/", spec_files(tag: "3"))
      assert {:error, {:spec, :stale_version, 2}} = import(ctx, archive, base_version: 1)
      assert {:error, {:spec, :stale_version, 2}} = import(ctx, archive, base_version: 5)

      assert {:error, {:spec, :invalid_params, %{field: :base_version}}} =
               import(ctx, archive, [])

      {_viewer, viewer_scope} = member_scope_fixture(ctx.workspace, :viewer)

      assert {:error, :forbidden} =
               TaskSpecs.import_archive(viewer_scope, ctx.ident, archive, base_version: 2)

      assert latest(ctx) == 2
    end

    test "links, devices, absolute paths, .., too many entries and too much data", ctx do
      ok = spec_files()["proposal.md"]

      archives = [
        {"symlink", tar([file("x/tasks.md", ok), {"x/proposal.md", "", "2", "/etc/passwd"}])},
        {"hard link", tar([file("x/tasks.md", ok), {"x/proposal.md", "", "1", "x/tasks.md"}])},
        {"device", tar([file("x/tasks.md", ok), {"x/proposal.md", "", "3", ""}])},
        {"absolute", tar([file("/x/proposal.md", ok)])},
        {"dot dot", tar([file("x/../proposal.md", ok)])},
        {"201 entries",
         tar([file("x/proposal.md", ok) | for(i <- 1..200, do: file("x/n#{i}.txt", "."))])},
        {"1 MB",
         tar([file("x/proposal.md", ok), file("x/big.txt", :binary.copy("a", 1024 * 1024))])},
        {"not an archive", "plain text"},
        {"damaged gzip", <<0x1F, 0x8B, 8, 0, 1, 2, 3>>},
        {"no spec file", tar([file("x/readme.txt", ok)])},
        {"zip dot dot", zip([{~c"x/../proposal.md", ok}])},
        {"zip absolute", rename(zip([{~c"xproposal.md", ok}]), "xproposal.md", "/proposal.md")},
        {"zip symlink", zip_symlink(zip([{~c"x/proposal.md", "/etc/passwd"}]))}
      ]

      expected = %{
        "symlink" => "\"x/proposal.md\" is not a regular file",
        "hard link" => "\"x/proposal.md\" is not a regular file",
        "device" => "\"x/proposal.md\" is not a regular file",
        "absolute" => "\"/x/proposal.md\" is an absolute path",
        "dot dot" => "\"x/../proposal.md\" is an absolute path or contains ..",
        "201 entries" => "more than 200 entries",
        "1 MB" => "holds more than 1 MB",
        "not an archive" => "not a tar.gz or zip",
        "damaged gzip" => "damaged",
        "no spec file" => "no spec file",
        "zip dot dot" => "contains ..",
        "zip absolute" => "\"/proposal.md\" is an absolute path",
        "zip symlink" => "\"x/proposal.md\" is not a regular file"
      }

      for {label, archive} <- archives do
        assert {:error, {:spec, :invalid_archive, message}} =
                 import(ctx, archive, base_version: 0),
               label

        assert message =~ expected[label], "#{label}: #{message}"
      end

      assert {:error, {:spec, :invalid_archive, _}} =
               import(ctx, :binary.copy("a", Archive.max_bytes() + 1), base_version: 0)

      assert {:ok, nil} = TaskSpecs.summary(ctx.alice_scope, ctx.ident)
    end

    test "a gzip that expands beyond the limit stops early", ctx do
      bomb = :zlib.gzip(:binary.copy(<<0>>, 64 * 1024 * 1024))
      assert byte_size(bomb) < Archive.max_bytes()

      assert {:error, {:spec, :invalid_archive, "the archive holds more than 1 MB"}} =
               import(ctx, bomb, base_version: 0)
    end
  end

  # `:zip.create/3` makes absolute names relative: rename in the bytes.
  defp rename(zip, from, to) when byte_size(from) == byte_size(to),
    do: :binary.replace(zip, from, to, [:global])

  # Marks the first central directory entry as a Unix symbolic link.
  defp zip_symlink(zip) do
    {at, _} = :binary.match(zip, <<"PK", 1, 2>>)
    <<head::binary-size(^at), entry::binary-46, rest::binary>> = zip

    <<signature::binary-4, version, _made_by, middle::binary-32, _external::32, local::binary-4>> =
      entry

    external = Bitwise.bsl(0o120777, 16)

    head <>
      <<signature::binary, version, 3, middle::binary, external::32-little, local::binary>> <>
      rest
  end

  defp zip(files) do
    {:ok, {_name, body}} = :zip.create(~c"x.zip", files, [:memory])
    body
  end

  @tag :openspec_cli
  @tag :tmp_dir
  test "openspec validate --strict accepts an export", %{tmp_dir: tmp} = ctx do
    openspec = System.find_executable("openspec") || flunk("openspec is not installed")
    spec_fixture(ctx.alice_scope, ctx.ident, versions: 2, change_id: "add-settings-page")
    {review, _run} = agent_run_scope(ctx.qa, ctx.task)

    {:ok, _} =
      TaskSpecs.submit_review(review, ctx.ident, %{
        version: 2,
        verdict: "comment",
        summary: "Fine.",
        issues: [%{severity: "P3", body: "Nit."}]
      })

    for {path, content} <- entries(export!(ctx, reviews: true)) do
      target = Path.join([tmp, "openspec/changes", path])
      File.mkdir_p!(Path.dirname(target))
      File.write!(target, content)
    end

    {output, status} =
      System.cmd(openspec, ["validate", "add-settings-page", "--strict", "--no-interactive"],
        cd: tmp,
        stderr_to_stdout: true
      )

    assert status == 0, output
  end
end
