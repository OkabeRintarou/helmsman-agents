defmodule HelmsmanMCP.Tools.ListActors do
  @moduledoc "`list_actors`: every identity of the workspace."

  use HelmsmanMCP.Tool,
    name: "list_actors",
    description:
      "List the identities of this workspace: humans, agents (with their owner, project, " <>
        "worktree and last seen time) and the system identity.",
    schema: %{},
    mode: :read

  alias Helmsman.Actors

  @impl HelmsmanMCP.Tool
  def call(_args, %{scope: scope}), do: Actors.list(scope)
end
