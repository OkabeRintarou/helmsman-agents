defmodule HelmsmanProtocol.Report.Events do
  @moduledoc "Report.Events protocol payload."
  use HelmsmanProtocol.Schema
  field(:run_id, :pos_integer)
  list(:events, HelmsmanProtocol.Event, min: 1, max: 200)

  def validate(value) do
    value.events
    |> Enum.with_index()
    |> Enum.reduce_while(0, fn {event, index}, previous ->
      if event.seq > previous,
        do: {:cont, event.seq},
        else: {:halt, HelmsmanProtocol.Schema.invalid(["events", index, "seq"], :not_increasing)}
    end)
    |> case do
      seq when is_integer(seq) -> {:ok, value}
      error -> error
    end
  end
end
