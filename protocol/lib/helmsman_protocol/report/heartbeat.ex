defmodule HelmsmanProtocol.Report.Heartbeat do
  @moduledoc "Report.Heartbeat protocol payload."
  use HelmsmanProtocol.Schema
  list(:runs, HelmsmanProtocol.ActiveRun)
end
