defmodule Helmsman.TaskSpecsFixtures do
  @moduledoc """
  Test helpers for `add-spec-workflow` (decision 24): `spec_files/1` (a
  set of files that passes validation), `spec_fixture/3` (a spec with
  versions), `specs_fixture/1` (the squads workspace with a task for
  `web-team`) and `agent_run_scope/3`.
  """

  use Boundary, top_level?: true, check: [in: false, out: false]

  import Helmsman.ProjectsFixtures
  import Helmsman.RunsFixtures
  import Helmsman.SquadsFixtures

  alias Helmsman.Actors.Actor
  alias Helmsman.{Tasks, TaskSpecs}

  @openspec_cases Path.expand("openspec", __DIR__)

  @doc "The directories of the OpenSpec conformance cases (decision 4)."
  def openspec_case_dirs,
    do: @openspec_cases |> Path.join("*") |> Path.wildcard() |> Enum.filter(&File.dir?/1)

  @doc "The files of a conformance case directory, `%{path => content}`, without `expected.json`."
  def openspec_case_files(dir) do
    dir
    |> Path.join("**/*")
    |> Path.wildcard(match_dot: true)
    |> Enum.filter(&File.regular?/1)
    |> Enum.reject(&(Path.basename(&1) == "expected.json"))
    |> Map.new(&{Path.relative_to(&1, dir), File.read!(&1)})
  end

  @doc """
  The files of a change that passes `Helmsman.TaskSpecs.Validate`.
  Options: `requirement` (the requirement's name, default "Save"),
  `tag` (a word put into every file so versions differ), `invalid` (no
  scenario: fails `requirement_no_scenario`).
  """
  def spec_files(opts \\ []) do
    name = Keyword.get(opts, :requirement, "Save")
    tag = Keyword.get(opts, :tag, "")

    scenario =
      if Keyword.get(opts, :invalid, false),
        do: "",
        else: "#### Scenario: Saved\n- **WHEN** a user saves\n- **THEN** it is stored\n"

    %{
      "proposal.md" =>
        "## Why\n\nSettings get lost. #{tag}\n\n## What Changes\n\n- A settings page.\n",
      "tasks.md" => "## 1. Settings\n\n- [ ] 1.1 Build the page #{tag}\n",
      "specs/settings/spec.md" =>
        "## ADDED Requirements\n\n### Requirement: #{name}\n" <>
          "The system MUST save the settings. #{tag}\n\n" <> scenario
    }
  end

  @doc """
  Creates the spec of the task `ident` as `scope` with `versions`
  versions (default 1; 0: an empty spec), each from `spec_files/1` with a
  different tag. Options: `change_id`, `files` (the first version's).
  Returns the summary.
  """
  def spec_fixture(scope, ident, opts \\ []) do
    versions = Keyword.get(opts, :versions, 1)

    if versions == 0 do
      {:ok, summary} = TaskSpecs.update(scope, ident, %{change_id: opts[:change_id]})
      summary
    else
      Enum.each(1..versions, &submit_fixture_version(scope, ident, &1, opts))
      {:ok, summary} = TaskSpecs.summary(scope, ident)
      summary
    end
  end

  defp submit_fixture_version(scope, ident, n, opts) do
    files = if n == 1, do: opts[:files] || spec_files(), else: spec_files(tag: "v#{n}")

    {:ok, %{version: ^n}} =
      TaskSpecs.submit_version(scope, ident, %{
        base_version: n - 1,
        files: files,
        remove: [],
        change_id: opts[:change_id]
      })
  end

  @doc """
  `squads_fixture/1` with `task`, a task of alice's project assigned to
  `web-team` (by alice: the squad holds her `assign` grant).
  """
  def specs_fixture(opts \\ %{}) do
    ctx = squads_fixture(opts)
    task = task_fixture(ctx.alice_scope, ctx.project.key)
    {:ok, _} = Tasks.update(ctx.alice_scope, task.ident, %{assignee: "web-team"})
    {:ok, task} = Tasks.get(ctx.alice_scope, task.ident)
    Map.put(ctx, :task, task)
  end

  @doc """
  The run-token scope of a `running` run of `agent` on `task`
  (`read`, `write_task`, and `delegate` as a squad's leader with
  `squad_id`). Returns `{scope, run}`.
  """
  def agent_run_scope(%Actor{} = agent, task, attrs \\ %{}) do
    squad_id = attrs[:squad_id]
    caps = if squad_id, do: ["read", "write_task", "delegate"], else: ["read", "write_task"]

    run =
      run_fixture(
        agent,
        Map.merge(%{task_id: task.id, status: :running, capabilities: caps}, Map.new(attrs))
      )

    {scope, _token} = run_scope_fixture(run)
    {scope, run}
  end
end
