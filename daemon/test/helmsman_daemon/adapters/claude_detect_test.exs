defmodule HelmsmanDaemon.Adapters.ClaudeDetectTest do
  use ExUnit.Case, async: true
  alias HelmsmanDaemon.Adapters.Claude

  test "version probe returns recorded model aliases and supported efforts" do
    assert {:ok,
            %{
              version: "2.1.246",
              models: ~w(fable opus sonnet),
              efforts: ~w(low medium high xhigh max)
            }} =
             Claude.detect(fn "claude" -> {:ok, "2.1.246 (Claude Code)"} end, fn ->
               {"1000\n", 0}
             end)
  end

  test "root is unavailable without invoking the version probe" do
    assert {:error, reason} = Claude.detect(fn _ -> flunk("root probe") end, fn -> {"0\n", 0} end)
    assert reason =~ "normal user"
  end

  test "old, invalid, missing and failed identity probes are unavailable" do
    for {output, reason} <- [
          {"2.0.9 (Claude Code)", "too old"},
          {"unknown", "Invalid"},
          {"version 2.1.0", "Invalid"}
        ] do
      assert {:error, error} = Claude.detect(fn _ -> {:ok, output} end, fn -> {"1000", 0} end)
      assert error =~ reason
    end

    assert {:error, "missing"} =
             Claude.detect(fn _ -> {:error, "missing"} end, fn -> {"1000", 0} end)

    assert {:error, _} = Claude.detect(fn _ -> flunk("identity failed") end, fn -> {"", 1} end)
  end
end
