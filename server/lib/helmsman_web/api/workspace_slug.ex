defmodule HelmsmanWeb.API.WorkspaceSlug do
  @moduledoc """
  The `:slug` of `/api/v1/w/:slug/…` must be the token's workspace
  (`add-rest-api` decision 1): any other slug is 404 `not_found`, whether
  or not that workspace exists.
  """

  @behaviour Plug

  alias HelmsmanWeb.ErrorMapper

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Plug.Conn{path_params: %{"slug" => slug}} = conn, _opts) do
    case conn.assigns[:current_scope] do
      %{workspace: %{slug: ^slug}} -> conn
      _other -> ErrorMapper.send_error(conn, ErrorMapper.to_response(:not_found))
    end
  end
end
