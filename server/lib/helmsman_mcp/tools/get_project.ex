defmodule HelmsmanMCP.Tools.GetProject do
  @moduledoc "`get_project`: one project by key."

  use HelmsmanMCP.Tool,
    name: "get_project",
    description: "Show a project by key (case-insensitive), archived ones included.",
    schema: %{key: {:required, :string, description: "Project key (e.g. BOS)."}},
    mode: :read

  alias Helmsman.Projects
  alias HelmsmanMCP.Present

  @impl HelmsmanMCP.Tool
  def call(%{"key" => key}, %{scope: scope}) do
    with {:ok, project} <- Projects.get(scope, key), do: {:ok, Present.project(project)}
  end
end
