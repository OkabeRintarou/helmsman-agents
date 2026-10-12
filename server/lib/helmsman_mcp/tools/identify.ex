defmodule HelmsmanMCP.Tools.Identify do
  @moduledoc """
  `identify`: sets the session identity (designs/03 §4). It writes, but
  it is the identity itself, so it does not go through the writer
  resolution and is declared `:read`.
  """

  use HelmsmanMCP.Tool,
    name: "identify",
    description:
      "Set the agent identity this session's writes are recorded as. Creates the agent " <>
        "(owned by you) if the name is new. Call it first in every session.",
    schema: %{
      name:
        {:required, :string,
         description: "Agent name, lower case, team/role style (e.g. keel/dev)."},
      project: {:string, description: "Key of the project you work on (e.g. KEEL)."},
      worktree: {:string, description: "Your git worktree or branch."},
      kind: {:string, description: "Accepted for compatibility; only \"agent\"."}
    },
    mode: :read

  alias Helmsman.Actors
  alias HelmsmanMCP.Identity

  @impl HelmsmanMCP.Tool
  def call(%{"kind" => kind}, _ctx) when kind not in [nil, "agent"],
    do: {:error, {:invalid_kind, kind}}

  # A run token is always its run's agent: nothing changes.
  def call(_args, %{scope: %{via: :run, actor: actor}}) do
    {:ok,
     %{
       name: actor.name,
       kind: actor.kind,
       project: actor.project_key,
       worktree: actor.worktree,
       source: "run"
     }}
  end

  def call(args, ctx) do
    attrs = %{name: args["name"], project: args["project"], worktree: args["worktree"]}

    with {:ok, actor} <- Actors.identify(ctx.scope, attrs) do
      Identity.put(ctx.session, actor, :identify)

      {:ok,
       %{
         name: actor.name,
         kind: actor.kind,
         project: actor.project_key,
         worktree: actor.worktree,
         source: "identify"
       }}
    end
  end
end
