defmodule HelmsmanProtocol.Report.Join do
  @moduledoc "Report.Join protocol payload."
  use HelmsmanProtocol.Schema
  field(:protocol, :pos_integer)
  embeds(:machine, HelmsmanProtocol.Machine)
  list(:clis, HelmsmanProtocol.CLI)
  field(:max_concurrency, :pos_integer)
  list(:active_runs, HelmsmanProtocol.ActiveRun)
end
