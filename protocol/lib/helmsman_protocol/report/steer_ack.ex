defmodule HelmsmanProtocol.Report.SteerAck do
  @moduledoc "Report.SteerAck protocol payload."
  use HelmsmanProtocol.Schema
  field(:run_id, :pos_integer)
  field(:feedback_id, :pos_integer)
end
