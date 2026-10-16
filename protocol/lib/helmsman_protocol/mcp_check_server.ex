defmodule HelmsmanProtocol.McpCheckServer do
  @moduledoc "Command and reference names for a local check; never argument or header values."
  use HelmsmanProtocol.Schema
  field(:name, :string, min_bytes: 1, max_bytes: 64)
  field(:type, {:enum, ~w(stdio http sse)a})
  field(:command, :string, nullable: true, max_bytes: 1_024)
  list(:env_refs, :string, max: 256, item_min_bytes: 1, item_max_bytes: 128)
end
