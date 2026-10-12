defmodule HelmsmanProtocol.Event.ToolResult do
  @moduledoc "Event.ToolResult protocol payload."
  use HelmsmanProtocol.Schema
  field(:call_id, :string, nullable: true)
  field(:output, :string, max_bytes: 16_384)
  field(:is_error, :boolean)
  field(:truncated, :boolean)
end
