defmodule HelmsmanProtocol.Push.Cancel do
  @moduledoc "Push.Cancel protocol payload."
  use HelmsmanProtocol.Schema
  field(:run_id, :pos_integer)
end
