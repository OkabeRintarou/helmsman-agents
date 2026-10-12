defmodule HelmsmanWeb.Plugs.MCPSessionGuard do
  @moduledoc """
  Binds MCP sessions to the token that opened them (designs/08 §1).

  Runs after `HelmsmanWeb.Plugs.BearerAuth`. A request without an
  `Mcp-Session-Id` header passes (anubis opens a session on `initialize`
  and refuses anything else). With the header, the session must be
  registered in `HelmsmanMCP.Sessions` for the very token of this request,
  `initialize` included; otherwise the answer is 404, as for an unknown
  session, and the request never reaches it.
  """

  @behaviour Plug

  import Plug.Conn

  alias HelmsmanMCP.Sessions

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    case get_req_header(conn, "mcp-session-id") do
      [] ->
        conn

      [session_id] ->
        token_id = conn.assigns.current_scope.token.id

        case Sessions.lookup(session_id) do
          %{token_id: ^token_id} ->
            :ok = Sessions.touch(session_id)
            conn

          _other ->
            not_found(conn)
        end

      _several ->
        not_found(conn)
    end
  end

  # The body anubis sends for an unknown session.
  defp not_found(conn) do
    body = %{
      jsonrpc: "2.0",
      id: nil,
      error: %{
        code: -32_600,
        message: "Invalid Request",
        data: %{message: "Session not found", http_status: 404}
      }
    }

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(404, Jason.encode!(body))
    |> halt()
  end
end
