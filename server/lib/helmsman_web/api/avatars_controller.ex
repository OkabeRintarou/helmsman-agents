defmodule HelmsmanWeb.API.AvatarsController do
  @moduledoc """
  `GET /api/v1/w/:slug/avatars/:key` (`add-actor-avatars` decisions 5
  and 13): the avatar addresses of the MCP and REST identity views, read
  with the same API token. The only REST endpoint that also accepts the
  `mcp` scope; run and daemon tokens are 401 as everywhere in REST. What
  it can read is what the workspace's members can; anything else is 404
  `not_found`.
  """

  use HelmsmanWeb.API.Controller

  alias Helmsman.Avatars
  alias HelmsmanWeb.AvatarResponse
  alias OpenApiSpex.Schema

  def show(conn, %{"key" => key}) do
    ToolAction.guarded(conn, "get_avatar", fn ->
      case Avatars.fetch_for_workspace(conn.assigns.current_scope.workspace.id, key) do
        {:ok, avatar} -> AvatarResponse.send(conn, avatar)
        :error -> {:error, :not_found}
      end
    end)
  end

  @doc false
  def operation(:show) do
    Operations.manual(
      id: "get_avatar",
      summary: "get_avatar",
      description:
        "An avatar's image, at the avatar_url of list_actors, list_agents, whoami and /me. " <>
          "Accepts a token with any of the scopes mcp, api:read and api:write. The response " <>
          "has the stored type (image/png, image/jpeg or image/webp), ETag \"<key>\" and is " <>
          "cached for a year (the key changes with the content); a request with a matching " <>
          "If-None-Match gets 304 without a body.",
      tag: "identities",
      params: [{:key, :path, %Schema{type: :string, pattern: "^[0-9a-f]{32}$"}, "Avatar key."}],
      content_type: "image/*",
      response: %Schema{type: :string, format: :binary}
    )
  end
end
