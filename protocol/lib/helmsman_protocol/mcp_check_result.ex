defmodule HelmsmanProtocol.McpCheckResult do
  @moduledoc "Local MCP check result without any expanded command or environment values."
  use HelmsmanProtocol.Schema
  field(:name, :string, min_bytes: 1, max_bytes: 64)
  field(:command_found, {:enum, [:yes, :no, :"n/a"]})
  list(:missing_env, :string, max: 256, item_min_bytes: 1, item_max_bytes: 128)
  field(:dropped, {:enum, [:unsupported_type, :missing_target]}, nullable: true)
end
