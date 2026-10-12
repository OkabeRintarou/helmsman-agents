defmodule HelmsmanProtocol.Report.Started do
  @moduledoc "Report.Started protocol payload."
  use HelmsmanProtocol.Schema
  field(:run_id, :pos_integer)
  field(:session_id, :string, nullable: true)
end
