defmodule HelmsmanWeb.API.PublicRateLimit do
  @moduledoc """
  The rate limit of the public REST endpoints (`add-rest-api` decision 9):
  per client IP (`Helmsman.RateLimit` bucket `:public_api_ip`); over it,
  429 `rate_limited` with `Retry-After`.
  """

  @behaviour Plug

  import Plug.Conn

  alias Helmsman.RateLimit
  alias HelmsmanWeb.ErrorMapper

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    case RateLimit.check_retry(:public_api_ip, RateLimit.ip_key(conn.remote_ip)) do
      :ok ->
        conn

      {:error, :rate_limited, retry_after_ms} ->
        conn
        |> put_resp_header("retry-after", Integer.to_string(max(1, ceil(retry_after_ms / 1000))))
        |> ErrorMapper.send_error({429, ErrorMapper.body("rate_limited")})
    end
  end
end
