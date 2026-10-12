defmodule HelmsmanMCP do
  @moduledoc """
  The MCP endpoint (designs/08): the anubis server, the tool behaviour and
  pipeline, the session table and the error texts shown to agents.

  Depends only on the domain layer; the web layer routes `/mcp` here.
  """

  use Boundary, deps: [Helmsman], exports: [Server, Sessions, Supervisor]
end
