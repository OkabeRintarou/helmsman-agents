defmodule HelmsmanProtocol.Event.Error do
  @moduledoc "Event.Error protocol payload."
  use HelmsmanProtocol.Schema
  field(:reason, {:enum, HelmsmanProtocol.FailureReason.daemon_reportable()})
  field(:message, :string, max_bytes: 16_384)
end
