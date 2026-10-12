defmodule HelmsmanProtocol.Report.Sync do
  @moduledoc "Report.Sync protocol payload."
  use HelmsmanProtocol.Schema
  embeds(:machine, HelmsmanProtocol.Machine)
  list(:clis, HelmsmanProtocol.CLI)
  field(:max_concurrency, :pos_integer)
end
