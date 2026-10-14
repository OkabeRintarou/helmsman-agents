defmodule HelmsmanWeb.AvatarResponse do
  @moduledoc """
  The response of the avatar read routes (`add-actor-avatars` decision 5):
  the stored content type, cached for a year (the key is the content
  hash), `ETag: "<key>"` with 304 on a matching `If-None-Match`, and
  headers that keep the bytes from being sniffed or run as a document.
  """

  import Plug.Conn

  @doc "Sends `avatar` (`Helmsman.Avatars.fetched()`), or 304."
  @spec send(Plug.Conn.t(), %{data: binary(), content_type: String.t(), key: String.t()}) ::
          Plug.Conn.t()
  def send(conn, %{data: data, content_type: content_type, key: key}) do
    etag = ~s("#{key}")

    conn =
      conn
      |> put_resp_header("cache-control", "private, max-age=31536000, immutable")
      |> put_resp_header("etag", etag)
      |> put_resp_header("x-content-type-options", "nosniff")
      |> put_resp_header("content-security-policy", "default-src 'none'; sandbox")

    if not_modified?(conn, etag) do
      send_resp(conn, 304, "")
    else
      conn
      |> put_resp_header("content-disposition", "inline")
      |> put_resp_content_type(content_type, nil)
      |> send_resp(200, data)
    end
  end

  defp not_modified?(conn, etag) do
    conn
    |> get_req_header("if-none-match")
    |> Enum.flat_map(&String.split(&1, ","))
    |> Enum.map(&String.trim/1)
    |> Enum.any?(&(&1 in ["*", etag, "W/" <> etag]))
  end
end
