defmodule HelmsmanProtocol.FinishedTest do
  use ExUnit.Case, async: true
  alias HelmsmanProtocol.{FailureReason, Fixtures, Report.Finished}

  test "failure codes exactly match the nineteen design codes and partition authority" do
    expected =
      ~w(runtime_offline daemon_restart lease_expired timeout stalled provider_network provider_rate_limit
      provider_auth provider_quota cli_missing cli_version workspace_prepare push_conflict push_failed context_overflow
      obsolete unauthorized cli_error unknown)a

    assert Enum.sort(FailureReason.all()) == Enum.sort(expected)
    daemon = MapSet.new(FailureReason.daemon_reportable())
    server = MapSet.new(FailureReason.server_only())
    assert MapSet.disjoint?(daemon, server)
    assert MapSet.union(daemon, server) == MapSet.new(expected)
  end

  test "failed if and only if daemon-reportable reason is supplied" do
    for reason <- FailureReason.server_only() ++ [:unexpected] do
      payload =
        Fixtures.finished()
        |> Map.merge(%{"status" => "failed", "failure_reason" => Atom.to_string(reason)})

      assert {:error, {:invalid_payload, ["failure_reason"], _}} = Finished.from_wire(payload)
    end

    for reason <- FailureReason.daemon_reportable() do
      payload =
        Fixtures.finished()
        |> Map.merge(%{"status" => "failed", "failure_reason" => Atom.to_string(reason)})

      assert {:ok, _} = Finished.from_wire(payload)
    end

    assert {:error, {:invalid_payload, ["failure_reason"], :required}} =
             Finished.from_wire(Map.put(Fixtures.finished(), "status", "failed"))

    for status <- ["succeeded", "cancelled"] do
      assert {:ok, _} = Finished.from_wire(Map.put(Fixtures.finished(), "status", status))

      assert {:error, {:invalid_payload, ["failure_reason"], :not_allowed}} =
               Finished.from_wire(
                 Fixtures.finished()
                 |> Map.merge(%{"status" => status, "failure_reason" => "timeout"})
               )
    end
  end

  test "summary and raw error limits, nullable usage" do
    for {key, max} <- [{"summary", 4_096}, {"error", 16_384}] do
      assert {:ok, _} =
               Finished.from_wire(Map.put(Fixtures.finished(), key, String.duplicate("x", max)))

      assert {:error, {:invalid_payload, [^key], {:too_long, ^max}}} =
               Finished.from_wire(
                 Map.put(Fixtures.finished(), key, String.duplicate("x", max + 1))
               )
    end

    assert {:ok, _} = Finished.from_wire(Map.put(Fixtures.finished(), "usage", nil))
  end

  test "error, session and summary may be null in all terminal statuses" do
    for status <- ["succeeded", "failed", "cancelled"] do
      reason = if status == "failed", do: "unknown", else: nil

      payload =
        Fixtures.finished()
        |> Map.merge(%{
          "status" => status,
          "failure_reason" => reason,
          "error" => nil,
          "session_id" => nil,
          "summary" => nil
        })

      assert {:ok, finished} = Finished.from_wire(payload)
      assert Finished.to_wire(finished) == payload
    end
  end
end
