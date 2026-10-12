defmodule HelmsmanProtocol.RunSpec.Trigger do
  @moduledoc "RunSpec.Trigger protocol payload."
  use HelmsmanProtocol.Schema
  field(:kind, :string, min_bytes: 1, max_bytes: 64)
  field(:reason, :string, min_bytes: 1, max_bytes: 64, nullable: true)
  field(:feedback_id, :pos_integer, nullable: true)
end
