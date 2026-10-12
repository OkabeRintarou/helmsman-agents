defmodule HelmsmanProtocol.ActiveRun do
  @moduledoc "ActiveRun protocol payload."
  use HelmsmanProtocol.Schema
  field(:run_id, :pos_integer)
  field(:last_seq, :non_neg_integer)
end
