defmodule HelmsmanWeb.Plugs.MCPMethod do
  @moduledoc """
  Puts the JSON-RPC method of an MCP request in the
  `x-helmsman-rpc-method` request header, replacing any the client sent
  (`add-agent-conversation` decision 7): `HelmsmanMCP.Server.server_tools/2`
  sees only the request's headers and lists the draft tools only for
  design runs, but keeps them for `tools/call`. A body that is not a single
  request (a batch, a notification without a method) gets no header.
  """

  @behaviour Plug

  import Plug.Conn

  @header "x-helmsman-rpc-method"

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    conn = delete_req_header(conn, @header)

    case conn.body_params do
      %{"method" => method} when is_binary(method) -> put_req_header(conn, @header, method)
      _other -> conn
    end
  end
end
