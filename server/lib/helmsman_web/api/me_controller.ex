defmodule HelmsmanWeb.API.MeController do
  @moduledoc """
  `/me` (who the token acts as, `add-rest-api` decision 7) and
  `/me/tasks` (`list_my_tasks`).
  """

  use HelmsmanWeb.API.Controller

  alias Helmsman.{Actors, Avatars}
  alias HelmsmanMCP.Present
  alias HelmsmanMCP.Tools.ListMyTasks
  alias HelmsmanWeb.API.Params

  tool_action(:tasks, ListMyTasks, response: Schemas.TaskList, tag: "identities")

  @sources %{requested: "header", default: "default", human: "human"}

  def show(conn, _params) do
    ToolAction.guarded(conn, "me", fn ->
      with {:ok, requested} <- Params.requested_actor(conn, nil),
           {:ok, scope, source} <- ToolAction.reader_scope(conn.assigns.current_scope, requested) do
        ToolAction.data(conn, 200, me(scope, source))
      end
    end)
  end

  defp me(scope, source) do
    human = Actors.get_human(scope.workspace.id, scope.user.id)
    token = scope.token
    appearance = Actors.appearance(scope)

    %{
      user:
        Map.merge(
          %{name: human && human.name},
          Present.avatar(scope, Avatars.user_avatar_key(scope.user.id))
        ),
      workspace: %{slug: scope.workspace.slug, name: scope.workspace.name},
      role: to_string(scope.role),
      actor:
        Present.put_avatar(
          %{name: scope.actor.name, kind: to_string(scope.actor.kind)},
          scope,
          appearance
        ),
      actor_source: Map.fetch!(@sources, source),
      token: %{
        name: token.name,
        prefix: token.prefix,
        scopes: token.scopes,
        expires_at: token.expires_at && DateTime.to_iso8601(token.expires_at)
      }
    }
  end

  @doc false
  def operation(:show) do
    Operations.manual(
      id: "me",
      summary: "me",
      description:
        "Who the token acts as: the user, the workspace and role, the current identity for " <>
          "reads (actor, and where it comes from: the X-Helmsman-Actor header, the token's " <>
          "default agent or your human identity) and the token. The user and the actor " <>
          "have has_avatar and avatar_url (readable with the same token, or null).",
      tag: "identities",
      response: Schemas.Me
    )
  end
end
