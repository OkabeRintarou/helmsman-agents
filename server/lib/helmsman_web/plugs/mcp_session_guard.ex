defmodule HelmsmanWeb.Plugs.MCPSessionGuard do
  @moduledoc """
  Binds MCP sessions to the credential that opened them (designs/08 §1):
  the API token, or the run of a run token.

  Runs after `HelmsmanWeb.Plugs.BearerAuth`. A request without an
  `Mcp-Session-Id` header passes (anubis opens a session on `initialize`
  and refuses anything else). With the header, the session must be
  registered in `HelmsmanMCP.Sessions` for the very credential of this
  request,
  `initialize` included; otherwise the answer is 404, as for an unknown
  session, and the request never reaches it.
  """

  @behaviour Plug

  import Plug.Conn

  alias Helmsman.Accounts.Scope
  alias HelmsmanMCP.Sessions

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    case get_req_header(conn, "mcp-session-id") do
      [] ->
        conn

      [session_id] ->
        credential = Scope.credential(conn.assigns.current_scope)

        case Sessions.lookup(session_id) do
          %{credential: ^credential} when not is_nil(credential) ->
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
