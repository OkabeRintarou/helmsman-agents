defmodule HelmsmanMCP.Tools.ListActors do
  @moduledoc "`list_actors`: every identity of the workspace."

  use HelmsmanMCP.Tool,
    name: "list_actors",
    description:
      "List the identities of this workspace: humans, agents (with their owner, project, " <>
        "worktree and last seen time) and the system identity. has_avatar tells whether " <>
        "an identity has an avatar; avatar_url is its address (readable with the same API " <>
        "token) or null.",
    schema: %{},
    mode: :read

  alias Helmsman.Actors
  alias HelmsmanMCP.Present

  @impl HelmsmanMCP.Tool
  def call(_args, %{scope: scope}) do
    with {:ok, actors} <- Actors.list(scope) do
      appearance = Actors.appearance(scope)
      {:ok, Enum.map(actors, &Present.put_avatar(&1, scope, appearance))}
    end
  end
end
