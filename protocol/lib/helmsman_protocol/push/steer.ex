defmodule HelmsmanProtocol.Push.Steer do
  @moduledoc "Push.Steer protocol payload."
  use HelmsmanProtocol.Schema
  field(:run_id, :pos_integer)
  field(:feedback_id, :pos_integer)
  field(:text, :string)
end
