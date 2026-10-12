defmodule HelmsmanProtocol.RunSpec.Limits do
  @moduledoc "RunSpec.Limits protocol payload."
  use HelmsmanProtocol.Schema
  field(:timeout_ms, :pos_integer)
  field(:idle_timeout_ms, :pos_integer)
end
