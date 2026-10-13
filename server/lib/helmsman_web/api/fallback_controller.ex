defmodule HelmsmanWeb.API.FallbackController do
  @moduledoc """
  Every `/api` path no route serves: 404 `not_found` with the REST error
  body, whatever the `Accept` header (`add-rest-api` decision 5).
  """

  use HelmsmanWeb, :controller

  alias HelmsmanWeb.ErrorMapper

  def not_found(conn, _params),
    do: ErrorMapper.send_error(conn, ErrorMapper.to_response(:not_found))
end
