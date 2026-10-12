defmodule HelmsmanProtocol.Report.Starting do
  @moduledoc "Report.Starting protocol payload."
  use HelmsmanProtocol.Schema
  field(:run_id, :pos_integer)
end
