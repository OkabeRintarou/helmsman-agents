defmodule HelmsmanProtocol.Event.Status do
  @moduledoc "Event.Status protocol payload."
  use HelmsmanProtocol.Schema
  field(:level, {:enum, [:info, :warning]})
  field(:message, :string, max_bytes: 4_096)
end
