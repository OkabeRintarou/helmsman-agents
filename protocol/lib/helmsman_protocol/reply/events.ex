defmodule HelmsmanProtocol.Reply.Events do
  @moduledoc "Reply.Events protocol payload."
  use HelmsmanProtocol.Schema
  field(:acked_seq, :non_neg_integer)
end
