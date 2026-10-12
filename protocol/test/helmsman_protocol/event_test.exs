defmodule HelmsmanProtocol.EventTest do
  use ExUnit.Case, async: true
  alias HelmsmanProtocol.{Event, Fixtures, Report}

  test "all nine event types validate and roundtrip" do
    assert Event.types() ==
             ~w(text thinking tool_call tool_result usage session result error status)a

    for type <- Event.types() do
      payload = Fixtures.event(Atom.to_string(type))
      assert {:ok, event} = Event.from_wire(payload)
      assert event.type == type
      assert Event.to_wire(event) == payload
      assert {:ok, ^event} = Event.new(Map.from_struct(event))
    end
  end

  test "strict types, reason authority and nested data fields" do
    assert {:error, {:invalid_payload, ["type"], _}} =
             Event.from_wire(Map.put(Fixtures.event(), "type", "progress"))

    assert {:error, {:invalid_payload, ["seq"], :type}} =
             Event.from_wire(Map.put(Fixtures.event(), "seq", 0))

    assert {:error, {:invalid_payload, ["data", "reason"], _}} =
             Event.from_wire(put_in(Fixtures.event("error"), ["data", "reason"], "lease_expired"))

    assert {:error, {:invalid_payload, ["data", "text"], :required}} =
             Event.from_wire(Map.put(Fixtures.event(), "data", %{}))
  end

  test "batches require strictly increasing sequences; gaps allowed" do
    for sequences <- [[3, 5, 4], [1, 1]] do
      events = Enum.map(sequences, &Fixtures.event("text", &1))

      assert {:error, {:invalid_payload, ["events", _, "seq"], :not_increasing}} =
               Report.Events.from_wire(%{"run_id" => 7, "events" => events})
    end

    assert {:ok, _} = Report.Events.from_wire(Fixtures.events())
  end

  test "byte limits are enforced without silently truncating payloads" do
    limits = [
      {"text", "text", 32_768},
      {"thinking", "text", 32_768},
      {"tool_call", "input", 32_768},
      {"tool_result", "output", 16_384},
      {"error", "message", 16_384},
      {"status", "message", 4_096}
    ]

    for {type, field, max} <- limits do
      payload = put_in(Fixtures.event(type), ["data", field], String.duplicate("a", max))
      assert {:ok, _} = Event.from_wire(payload)

      assert {:error, {:invalid_payload, ["data", ^field], {:too_long, ^max}}} =
               Event.from_wire(put_in(payload, ["data", field], String.duplicate("a", max + 1)))
    end
  end

  test "truncate handles codepoint boundaries including chinese and emoji" do
    text = String.duplicate("中😀", 3_000)
    {output, truncated} = Event.truncate(text, 16_384)
    assert truncated
    assert byte_size(output) <= 16_384
    assert String.valid?(output)

    payload =
      Fixtures.event("tool_result")
      |> put_in(["data", "output"], output)
      |> put_in(["data", "truncated"], truncated)

    assert {:ok, _} = Event.from_wire(payload)

    for text <- ["中文", "😀😀", "a中😀"], limit <- 0..byte_size(text) do
      {output, truncated} = Event.truncate(text, limit)
      assert String.valid?(output)
      assert byte_size(output) <= limit
      assert String.starts_with?(text, output)
      assert truncated == byte_size(text) > limit
    end

    assert Event.truncate("ok", 20) == {"ok", false}
  end

  test "unreported usage remains null, is nonnegative and keys are required" do
    payload = Map.new(Fixtures.usage(), fn {key, _} -> {key, nil} end)
    assert {:ok, usage} = Event.Usage.from_wire(payload)
    assert Event.Usage.to_wire(usage) == payload

    for key <- Map.keys(payload) do
      assert {:error, {:invalid_payload, [^key], :required}} =
               Event.Usage.from_wire(Map.delete(payload, key))

      assert {:error, {:invalid_payload, [^key], :type}} =
               Event.Usage.from_wire(Map.put(payload, key, -1))
    end
  end
end
