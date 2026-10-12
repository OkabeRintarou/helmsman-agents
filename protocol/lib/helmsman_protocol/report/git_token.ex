defmodule HelmsmanProtocol.Report.GitToken do
  @moduledoc "Report.GitToken protocol payload."
  use HelmsmanProtocol.Schema
  field(:run_id, :pos_integer)
end
