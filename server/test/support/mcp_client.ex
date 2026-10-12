defmodule HelmsmanWeb.MCPClient do
  @moduledoc """
  A small MCP client for tests: JSON-RPC over HTTP to `/mcp` with Req,
  through the whole endpoint (`HelmsmanWeb.Endpoint` as Req's plug: no
  listening socket needed), the way an agent's CLI talks to it.
  """

  use Boundary, top_level?: true, check: [in: false, out: false]

  @version "2025-06-18"

  @doc "Sends `body` to `/mcp` with `token` and the session ID `sid`."
  def post(token, sid, body) do
    headers =
      [
        {"accept", "application/json"},
        {"content-type", "application/json"},
        {"mcp-protocol-version", @version}
      ] ++
        if(token, do: [{"authorization", "Bearer " <> token}], else: []) ++
        if(sid, do: [{"mcp-session-id", sid}], else: [])

    Req.post!("http://localhost/mcp",
      plug: HelmsmanWeb.Endpoint,
      headers: headers,
      body: Jason.encode!(body),
      decode_body: false,
      retry: false
    )
  end

  @doc "A JSON-RPC request; the response."
  def rpc(token, sid, method, params \\ %{}) do
    post(token, sid, %{
      jsonrpc: "2.0",
      id: System.unique_integer([:positive]),
      method: method,
      params: params
    })
  end

  @doc """
  `initialize` then `notifications/initialized`: the session ID, whose
  process is killed when the test exits. Raises unless both succeed.
  """
  def handshake(token) do
    params = %{
      protocolVersion: @version,
      capabilities: %{},
      clientInfo: %{name: "test-client", version: "1.0.0"}
    }

    resp = rpc(token, nil, "initialize", params)
    200 = resp.status
    [sid] = Req.Response.get_header(resp, "mcp-session-id")
    202 = post(token, sid, %{jsonrpc: "2.0", method: "notifications/initialized"}).status
    ExUnit.Callbacks.on_exit(fn -> kill_session(sid) end)
    sid
  end

  @doc """
  Calls the tool `name`: `{:ok, decoded_json}` or `{:error, text}` (an
  `isError` result).
  """
  def call_tool(token, sid, name, args \\ %{}) do
    resp = rpc(token, sid, "tools/call", %{name: name, arguments: args})
    200 = resp.status

    %{"result" => %{"content" => [%{"type" => "text", "text" => text}]} = result} =
      Jason.decode!(resp.body)

    if result["isError"], do: {:error, text}, else: {:ok, Jason.decode!(text)}
  end

  @doc "Kills the session process of `sid`, if any."
  def kill_session(sid) do
    registry_mod = Anubis.Server.Supervisor.get_session_config(HelmsmanMCP.Server).registry_mod
    registry = Anubis.Server.Registry.registry_name(HelmsmanMCP.Server)

    case registry_mod.lookup_session(registry, sid) do
      {:ok, pid} -> Process.exit(pid, :kill)
      _none -> :ok
    end

    :ok
  end
end
