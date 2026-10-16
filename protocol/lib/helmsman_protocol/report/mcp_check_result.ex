defmodule HelmsmanProtocol.Report.McpCheckResult do
  @moduledoc "The answer to a local MCP check."
  use HelmsmanProtocol.Schema
  field(:check_id, :string, min_bytes: 1, max_bytes: 64)
  list(:results, HelmsmanProtocol.McpCheckResult, max: 64)
end
