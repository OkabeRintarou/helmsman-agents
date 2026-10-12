defmodule HelmsmanProtocol.Event.Thinking do
  @moduledoc "Event.Thinking protocol payload."
  use HelmsmanProtocol.Schema
  field(:text, :string, max_bytes: 32_768)
end
