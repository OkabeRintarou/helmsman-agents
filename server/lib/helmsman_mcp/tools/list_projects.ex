defmodule HelmsmanMCP.Tools.ListProjects do
  @moduledoc "`list_projects`: the workspace's projects."

  use HelmsmanMCP.Tool,
    name: "list_projects",
    description:
      "List the projects of this workspace by key: name, description, whether archived " <>
        "and task count. Archived projects are left out unless include_archived is true.",
    schema: %{
      include_archived: {:boolean, description: "Also list archived projects (default false)."}
    },
    mode: :read

  alias Helmsman.Projects
  alias HelmsmanMCP.Present

  @impl HelmsmanMCP.Tool
  def call(args, %{scope: scope}) do
    with {:ok, projects} <-
           Projects.list(scope, include_archived: args["include_archived"] == true) do
      {:ok, Enum.map(projects, &Present.project/1)}
    end
  end
end
