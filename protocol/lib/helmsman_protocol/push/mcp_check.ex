defmodule HelmsmanProtocol.Push.McpCheck do
  @moduledoc "Local MCP check in this agent's execution environment."
  use HelmsmanProtocol.Schema
  field(:check_id, :string, min_bytes: 1, max_bytes: 64)
  field(:runtime_id, :pos_integer)
  field(:agent_env, :string_map)
  list(:servers, HelmsmanProtocol.McpCheckServer, max: 64)
  use HelmsmanProtocol.Redacted, [:agent_env]
end
