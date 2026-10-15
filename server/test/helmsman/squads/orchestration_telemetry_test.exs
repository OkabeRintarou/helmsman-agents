defmodule Helmsman.Squads.OrchestrationTelemetryTest do
  # improve-squad-leader-orchestration 4.5 (decision 17): the counters of
  # orchestration writes and stall checks. The events themselves are
  # emitted by `Helmsman.Squads.Orchestration` and `EpicWatch` (groups 1–2).
  use ExUnit.Case, async: true

  alias Telemetry.Metrics.Counter

  test "the counters by result" do
    metrics = Map.new(HelmsmanWeb.Telemetry.metrics(), &{&1.name, &1})

    assert %Counter{tags: [:action, :result]} =
             metrics[[:helmsman, :orchestration, :write, :count]]

    assert %Counter{tags: [:result]} =
             metrics[[:helmsman, :epic_watch, :check, :count]]
  end

  test "the counters follow the events", %{test: test} do
    parent = self()

    :telemetry.attach_many(
      "#{test}",
      [[:helmsman, :orchestration, :write], [:helmsman, :epic_watch, :check]],
      fn event, measurements, metadata, _config ->
        send(parent, {event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach("#{test}") end)

    :telemetry.execute([:helmsman, :epic_watch, :check], %{count: 1}, %{result: :same_signature})
    assert_received {[:helmsman, :epic_watch, :check], %{count: 1}, %{result: :same_signature}}
  end
end
