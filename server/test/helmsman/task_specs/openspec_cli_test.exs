defmodule Helmsman.TaskSpecs.OpenspecCliTest do
  # add-spec-workflow 1.2: every conformance case that Helmsman accepts must
  # pass `openspec validate <id> --strict` as well (decision 4). Needs the
  # `openspec` executable; run with `mix test --only openspec_cli`.
  use ExUnit.Case, async: true

  import Helmsman.TaskSpecsFixtures, only: [openspec_case_dirs: 0, openspec_case_files: 1]

  alias Helmsman.TaskSpecs.Validate

  @moduletag :openspec_cli
  @moduletag :tmp_dir

  test "openspec validate --strict accepts every case Helmsman accepts", %{tmp_dir: tmp} do
    openspec = System.find_executable("openspec") || flunk("openspec is not installed")
    changes = Path.join(tmp, "openspec/changes")

    accepted =
      for dir <- openspec_case_dirs(),
          files = openspec_case_files(dir),
          Validate.run(files).valid do
        id = Path.basename(dir)

        for {path, content} <- files do
          target = Path.join([changes, id, path])
          File.mkdir_p!(Path.dirname(target))
          File.write!(target, content)
        end

        id
      end

    assert length(accepted) >= 10

    for id <- accepted do
      {output, status} =
        System.cmd(openspec, ["validate", id, "--strict", "--no-interactive"],
          cd: tmp,
          stderr_to_stdout: true
        )

      assert status == 0, "openspec rejected #{id}:\n#{output}"
    end
  end
end
