defmodule HelmsmanWeb.DaemonDeviceController do
  use HelmsmanWeb, :controller
  alias Helmsman.Daemons
  alias HelmsmanProtocol.DeviceAuth.{CodeRequest, CodeResponse, TokenRequest, TokenResponse}
  alias HelmsmanProtocol.ErrorReply

  def upgrade_url,
    do:
      Application.get_env(
        :helmsman,
        :daemon_upgrade_url,
        HelmsmanWeb.Endpoint.url() <> "/install.sh"
      )

  def code(conn, params) do
    case Helmsman.RateLimit.check(:daemon_device_ip, Helmsman.RateLimit.ip_key(conn.remote_ip)) do
      :ok -> issue_code(conn, params)
      _ -> conn |> put_status(429) |> json(%{error: "rate_limited"})
    end
  end

  defp issue_code(conn, params) do
    case decode_code(params) do
      {:ok, request} ->
        code_response(conn, request)

      _ ->
        {:ok, error} = ErrorReply.new(:invalid_payload, "invalid payload")
        conn |> put_status(400) |> json(ErrorReply.to_wire(error))
    end
  end

  defp decode_code(%{"protocol" => protocol} = params) when is_integer(protocol) do
    with {:ok, request} <-
           CodeRequest.from_wire(Map.put(params, "protocol", HelmsmanProtocol.version())) do
      {:ok, %{request | protocol: protocol}}
    end
  end

  defp decode_code(params), do: CodeRequest.from_wire(params)

  defp code_response(conn, request) do
    if HelmsmanProtocol.compatible?(request.protocol) do
      {:ok, code} = Daemons.start_device_auth(request)
      url = HelmsmanWeb.Endpoint.url() <> "/device"

      {:ok, response} =
        CodeResponse.new(
          Map.merge(code, %{
            verification_uri: url,
            verification_uri_complete: url <> "?code=" <> code.user_code
          })
        )

      json(conn, CodeResponse.to_wire(response))
    else
      {:ok, error} = ErrorReply.unsupported_protocol(upgrade_url())
      conn |> put_status(426) |> json(ErrorReply.to_wire(error))
    end
  end

  def token(conn, params) do
    result =
      with {:ok, request} <- TokenRequest.from_wire(params),
           do: Daemons.exchange_device_code(request.device_code)

    case result do
      {:ok, response} ->
        json(conn, TokenResponse.to_wire(response))

      {kind, reason} when kind in [:pending, :error] and is_atom(reason) ->
        conn |> put_status(400) |> json(%{error: Atom.to_string(reason)})

      _ ->
        conn |> put_status(400) |> json(%{error: "expired_token"})
    end
  end

  def logout(conn, _params) do
    token = conn |> get_req_header("x-helmsman-token") |> List.first()

    case Daemons.logout(token) do
      {:ok, _} -> json(conn, %{})
      {:error, :busy} -> conn |> put_status(503) |> json(%{})
      _ -> conn |> put_status(401) |> json(%{})
    end
  end
end
