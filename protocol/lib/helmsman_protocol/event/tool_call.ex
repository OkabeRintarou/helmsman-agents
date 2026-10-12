defmodule HelmsmanProtocol.Event.ToolCall do
  @moduledoc "Event.ToolCall protocol payload."
  use HelmsmanProtocol.Schema
  field(:call_id, :string, nullable: true)
  field(:name, :string)
  field(:input, :string, max_bytes: 32_768)
end
