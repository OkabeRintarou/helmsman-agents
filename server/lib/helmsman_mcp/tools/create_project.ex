defmodule HelmsmanMCP.Tools.CreateProject do
  @moduledoc "`create_project`: a new project (admins and above)."

  use HelmsmanMCP.Tool,
    name: "create_project",
    description:
      "Create a project (admins and owners only). The key is 2-10 characters of A-Z and " <>
        "0-9 starting with a letter; it prefixes task IDs (KEY-1) and never changes.",
    schema: %{
      key: {:required, :string, description: "Project key (e.g. BOS); upcased."},
      name: {:required, :string, description: "Project name, 1-80 characters."},
      description: {:string, description: "Markdown description."}
    },
    mode: :write

  alias Helmsman.Projects
  alias HelmsmanMCP.{Args, Present}

  @impl HelmsmanMCP.Tool
  def call(args, %{scope: scope}) do
    with {:ok, project} <- Projects.create(scope, Args.take(args, [:key, :name, :description])) do
      {:ok, Present.project(project)}
    end
  end
end
