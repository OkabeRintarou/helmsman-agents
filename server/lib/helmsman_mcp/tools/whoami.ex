defmodule HelmsmanMCP.Tools.Whoami do
  @moduledoc "`whoami`: the current identity, the user and the workspace."

  use HelmsmanMCP.Tool,
    name: "whoami",
    description:
      "Show the identity your writes are recorded as and where it comes from " <>
        "(identify, auto, default or none), your user and role, and the workspace.",
    schema: %{},
    mode: :read

  alias Helmsman.Actors
  alias HelmsmanMCP.{Identity, Present}

  @impl HelmsmanMCP.Tool
  def call(_args, %{scope: scope, session: session}) do
    human = Actors.get_human(scope.workspace.id, scope.user.id)

    {:ok,
     %{
       actor: actor_view(scope, scope.actor),
       source: Identity.source(scope, session),
       user: %{name: human && human.name, role: scope.role},
       workspace: %{slug: scope.workspace.slug, name: scope.workspace.name}
     }}
  end

  defp actor_view(_scope, nil), do: nil

  defp actor_view(scope, actor) do
    %{name: actor.name, kind: actor.kind, disabled: not is_nil(actor.disabled_at)}
    |> Present.put_avatar(scope, Actors.appearance(scope))
  end
end
