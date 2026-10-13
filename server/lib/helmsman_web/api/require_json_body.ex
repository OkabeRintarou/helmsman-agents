defmodule HelmsmanWeb.API.RequireJSONBody do
  @moduledoc """
  REST requests with a body must send JSON (`add-rest-api` decision 1):
  a `POST`, `PATCH`, `PUT` or `DELETE` with a body and a `content-type`
  other than `application/json` (or `+json`) is 415
  `unsupported_media_type`. Requests without a body are not checked.
  """

  @behaviour Plug

  import Plug.Conn

  alias HelmsmanWeb.ErrorMapper
  alias Plug.Conn.Utils

  @methods ~w(POST PATCH PUT DELETE)

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Plug.Conn{method: method} = conn, _opts) when method in @methods do
    if body?(conn) and not json?(conn) do
      ErrorMapper.send_error(conn, {415, ErrorMapper.body("unsupported_media_type")})
    else
      conn
    end
  end

  def call(conn, _opts), do: conn

  defp body?(conn) do
    case get_req_header(conn, "content-length") do
      [length | _] -> length |> String.trim() |> Integer.parse() |> positive?()
      # Chunked, or a content type without a length: treat as a body.
      [] -> get_req_header(conn, "transfer-encoding") != [] or content_type(conn) != nil
    end
  end

  defp positive?({n, ""}), do: n > 0
  defp positive?(_invalid), do: true

  defp json?(conn) do
    case content_type(conn) && Utils.content_type(content_type(conn)) do
      {:ok, "application", "json", _params} -> true
      {:ok, "application", subtype, _params} -> String.ends_with?(subtype, "+json")
      _other -> false
    end
  end

  defp content_type(conn) do
    case get_req_header(conn, "content-type") do
      [type | _] -> type
      [] -> nil
    end
  end
end
