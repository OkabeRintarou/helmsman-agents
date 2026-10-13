defmodule HelmsmanProtocol.CopilotUsageTest do
  use ExUnit.Case, async: true
  alias HelmsmanProtocol.{Event, Fixtures, Report}

  test "old and new usage roundtrip without a protocol version change" do
    old = Fixtures.usage()

    for wire <- [old, Map.merge(old, %{"reasoning_tokens" => 12, "premium_requests" => 0.5})] do
      assert {:ok, usage} = Event.Usage.from_wire(wire)
      assert Event.Usage.to_wire(usage) == wire
      event_wire = put_in(Fixtures.event("usage"), ["data"], wire)
      assert {:ok, event} = Event.from_wire(event_wire)
      assert Event.to_wire(event) == event_wire
      finished_wire = Fixtures.finished() |> Map.put("usage", wire)
      assert {:ok, finished} = Report.Finished.from_wire(finished_wire)
      assert Report.Finished.to_wire(finished) == finished_wire
    end

    for {key, bad} <- [
          {"reasoning_tokens", -1},
          {"reasoning_tokens", 1.5},
          {"premium_requests", -0.5}
        ] do
      assert {:error, _} = Event.Usage.from_wire(Map.put(old, key, bad))
    end

    assert {:ok, usage} =
             Event.Usage.from_wire(
               Map.merge(old, %{"reasoning_tokens" => nil, "premium_requests" => nil})
             )

    assert usage.reasoning_tokens == nil and usage.premium_requests == nil
  end
end
