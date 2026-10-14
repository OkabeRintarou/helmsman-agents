defmodule HelmsmanWeb.AvatarController do
  @moduledoc """
  The browser's avatar read routes (`add-actor-avatars` decision 5):
  `/w/:slug/avatars/:key` for the workspace's members (any role) and
  `/users/avatar/:key` for the user's own avatar. Anything not readable
  (no session, not a member, an unknown, foreign or malformed key) is an
  empty 404.
  """

  use HelmsmanWeb, :controller

  alias Helmsman.Accounts.{Scope, User}
  alias Helmsman.{Avatars, Workspaces}
  alias HelmsmanWeb.AvatarResponse

  def workspace(conn, %{"slug" => slug, "key" => key}) do
    with %Scope{user: %User{} = user} <- conn.assigns[:current_scope],
         {:ok, %{workspace: workspace}} <- Workspaces.fetch_for_user(user, slug),
         {:ok, avatar} <- Avatars.fetch_for_workspace(workspace.id, key) do
      AvatarResponse.send(conn, avatar)
    else
      _ -> not_found(conn)
    end
  end

  def own(conn, %{"key" => key}) do
    with %Scope{user: %User{id: user_id}} <- conn.assigns[:current_scope],
         {:ok, avatar} <- Avatars.fetch_own(user_id, key) do
      AvatarResponse.send(conn, avatar)
    else
      _ -> not_found(conn)
    end
  end

  defp not_found(conn), do: send_resp(conn, 404, "")
end
