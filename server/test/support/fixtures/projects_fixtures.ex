defmodule Helmsman.ProjectsFixtures do
  @moduledoc """
  Test helpers for projects and tasks.
  """

  # Test-only helpers used by both domain and web test cases.
  use Boundary, top_level?: true, check: [in: false, out: false]

  alias Helmsman.Projects
  alias Helmsman.Tasks

  def unique_project_key, do: "P#{rem(System.unique_integer([:positive]), 100_000_000)}"

  @doc "Creates a project as `scope` (an admin or owner)."
  def project_fixture(scope, attrs \\ %{}) do
    attrs = Enum.into(attrs, %{key: unique_project_key(), name: "Project"})
    {:ok, project} = Projects.create(scope, attrs)
    project
  end

  @doc "Creates a task in the project with `key` as `scope`."
  def task_fixture(scope, key, attrs \\ %{}) do
    attrs = Enum.into(attrs, %{title: "Task #{System.unique_integer([:positive])}"})
    {:ok, task} = Tasks.create(scope, key, attrs)
    task
  end
end
