defmodule HelmsmanDaemon.EventBufferTest do
  use ExUnit.Case, async: true
  alias HelmsmanDaemon.EventBuffer

  test "continuous numbering, 200 batch limit, acknowledgements and immutable retries" do
    buffer =
      Enum.reduce(1..450, EventBuffer.new(), fn n, acc ->
        EventBuffer.append(acc, :text, %{text: to_string(n)})
      end)

    {first, buffer} = EventBuffer.take_batch(buffer, 0)
    assert Enum.map(first, & &1.seq) == Enum.to_list(1..200)
    {[], _} = EventBuffer.take_batch(buffer, 1_000)
    {[], _} = EventBuffer.take_batch(EventBuffer.failed(buffer), 999)
    {retry, buffer} = EventBuffer.take_batch(EventBuffer.failed(buffer), 1_000)
    assert retry == first
    {second, _} = EventBuffer.take_batch(EventBuffer.ack(buffer, 200), 2_000)
    assert Enum.map(second, & &1.seq) == Enum.to_list(201..400)
  end

  test "shedding preserves sequence and important events with one warning" do
    buffer =
      Enum.reduce(1..10_001, EventBuffer.new(), fn _, acc ->
        EventBuffer.append(acc, :text, %{text: "x"})
      end)

    buffer =
      buffer
      |> EventBuffer.append(:thinking, %{text: "drop"})
      |> EventBuffer.append(:tool_result, %{tool_call_id: "x", content: "drop"})

    buffer = EventBuffer.append(buffer, :text, %{text: "keep"})
    events = :queue.to_list(buffer.pending)
    assert buffer.dropped == 2
    assert Enum.count(events, &(&1.type == :status)) == 1
    assert Enum.map(events, & &1.seq) == Enum.to_list(1..10_003)
    assert List.last(events).data.text == "keep"
  end
end
