defmodule HelmsmanProtocol.Event.Usage do
  @moduledoc "Event.Usage protocol payload."
  use HelmsmanProtocol.Schema
  field(:input_tokens, :non_neg_integer, nullable: true, required: true)
  field(:output_tokens, :non_neg_integer, nullable: true, required: true)
  field(:cache_read_tokens, :non_neg_integer, nullable: true, required: true)
  field(:cache_write_tokens, :non_neg_integer, nullable: true, required: true)
  field(:cost_usd, :number, nullable: true, required: true)
  field(:reasoning_tokens, :non_neg_integer, nullable: true, required: false)
  field(:premium_requests, :number, nullable: true, required: false)

  def to_wire(%__MODULE__{} = usage) do
    usage
    |> HelmsmanProtocol.Schema.encode(__schema__())
    |> Map.reject(fn {key, value} ->
      key in ["reasoning_tokens", "premium_requests"] and is_nil(value)
    end)
  end
end
