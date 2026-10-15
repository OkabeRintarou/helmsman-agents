defmodule Helmsman.TaskSpecs.ValidateTest do
  # add-spec-workflow 1.2: every conformance case under
  # test/support/fixtures/openspec/<case>/ against its expected.json
  # (decision 4).
  use ExUnit.Case, async: true

  import Helmsman.TaskSpecsFixtures, only: [openspec_case_dirs: 0, openspec_case_files: 1]

  alias Helmsman.TaskSpecs.Validate

  for dir <- openspec_case_dirs() do
    name = Path.basename(dir)
    @dir dir

    test "case #{name}" do
      expected = @dir |> Path.join("expected.json") |> File.read!() |> Jason.decode!()
      result = Validate.run(openspec_case_files(@dir))

      errors =
        for e <- result.errors, do: %{"file" => e.file, "line" => e.line, "rule" => e.rule}

      assert %{"valid" => result.valid, "errors" => errors} == expected
      assert Enum.all?(result.errors, &(is_binary(&1.message) and &1.message != ""))
    end
  end

  test "the rule codes are the documented ones" do
    rules =
      for dir <- openspec_case_dirs(),
          e <- Jason.decode!(File.read!(Path.join(dir, "expected.json")))["errors"],
          uniq: true,
          do: e["rule"]

    assert Enum.sort(rules) ==
             Enum.sort(~w(no_deltas no_delta_sections requirement_text_missing
                         requirement_no_normative requirement_no_scenario duplicate_requirement
                         requirement_conflict renamed_malformed missing_proposal
                         proposal_sections missing_tasks tasks_no_items))
  end

  test "a long closing fence closes a shorter one; a shorter one does not" do
    spec = fn fence_close ->
      "## ADDED Requirements\n\n### Requirement: A\nThe system MUST work.\n\n" <>
        "````\nx\n#{fence_close}\n#### Scenario: S\n- **WHEN** x\n"
    end

    files = %{
      "proposal.md" => "## Why\nx\n## What Changes\ny\n",
      "tasks.md" => "- [ ] a\n"
    }

    assert Validate.run(Map.put(files, "specs/a/spec.md", spec.("`````"))).valid

    refute Validate.run(Map.put(files, "specs/a/spec.md", spec.("```"))).valid
  end

  test "the message names the requirement" do
    files = %{
      "proposal.md" => "## Why\nx\n## What Changes\ny\n",
      "tasks.md" => "- [ ] a\n",
      "specs/settings/spec.md" =>
        "## ADDED Requirements\n\n### Requirement: Save\nThe system MUST.\n"
    }

    assert [%{message: ~s(ADDED "Save" must include at least one "#### Scenario:" block)}] =
             Validate.run(files).errors
  end
end
