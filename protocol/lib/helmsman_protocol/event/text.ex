defmodule HelmsmanProtocol.Event.Text do
  @moduledoc "Event.Text protocol payload."
  use HelmsmanProtocol.Schema
  field(:text, :string, max_bytes: 32_768)
end
