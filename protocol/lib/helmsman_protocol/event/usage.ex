defmodule HelmsmanProtocol.Event.Usage do
  @moduledoc "Event.Usage protocol payload."
  use HelmsmanProtocol.Schema
  field(:input_tokens, :non_neg_integer, nullable: true, required: true)
  field(:output_tokens, :non_neg_integer, nullable: true, required: true)
  field(:cache_read_tokens, :non_neg_integer, nullable: true, required: true)
  field(:cache_write_tokens, :non_neg_integer, nullable: true, required: true)
  field(:cost_usd, :number, nullable: true, required: true)
end
