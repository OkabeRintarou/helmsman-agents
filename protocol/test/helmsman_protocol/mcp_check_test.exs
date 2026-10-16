defmodule HelmsmanProtocol.McpCheckTest do
  use ExUnit.Case, async: true
  alias HelmsmanProtocol.{Fixtures, Messages, Push, Reply, Report}

  test "merge warnings accept the specified count and byte boundaries" do
    payload = Fixtures.replies()["claim"]
    [run | rest] = payload["runs"]
    warning = String.duplicate("w", 256)
    at_limit = put_in(run, ["agent", "mcp_warnings"], List.duplicate(warning, 16))
    assert {:ok, _} = Reply.Claim.from_wire(%{payload | "runs" => [at_limit | rest]})

    for warnings <- [List.duplicate(warning, 17), [warning <> "w"]] do
      invalid = put_in(run, ["agent", "mcp_warnings"], warnings)
      assert {:error, _} = Reply.Claim.from_wire(%{payload | "runs" => [invalid | rest]})
    end
  end

  test "merge warnings reach supported daemons and disappear from older claim payloads" do
    payload = Fixtures.replies()["claim"]
    [run | rest] = payload["runs"]
    run = put_in(run, ["agent", "mcp_warnings"], ["Personal definition overridden"])

    assert {:ok, claim} =
             Reply.Claim.from_wire(%{payload | "runs" => [run | rest]})

    assert {:ok, current} = Messages.encode_reply("claim", claim)
    assert hd(current["runs"])["agent"]["mcp_warnings"] == ["Personal definition overridden"]

    assert {:ok, older} =
             Messages.encode_reply("claim", claim, HelmsmanProtocol.mcp_env_version() - 1)

    refute Map.has_key?(hd(older["runs"])["agent"], "mcp_warnings")
  end

  test "local checks roundtrip, redact agent environment, reject old daemon" do
    wire = %{
      "check_id" => "c1",
      "runtime_id" => 1,
      "agent_env" => %{"KEY" => "canary"},
      "servers" => [
        %{"name" => "docs", "type" => "stdio", "command" => "${env:BIN}", "env_refs" => ["BIN"]}
      ]
    }

    assert {:ok, %Push.McpCheck{} = request} = Messages.decode("mcp_check", wire)
    refute inspect(request) =~ "canary"
    assert {:ok, {"mcp_check", ^wire}} = Messages.encode(request)

    assert {:error, {:not_in_version, _}} =
             Messages.encode(request, HelmsmanProtocol.mcp_env_version() - 1)

    assert {:error, _} =
             Messages.decode(
               "mcp_check",
               Map.put(wire, "servers", List.duplicate(hd(wire["servers"]), 65))
             )
  end

  test "results accept only yes/no/n/a and at most 64 entries" do
    for found <- ["yes", "no", "n/a"] do
      wire = %{
        "check_id" => "c1",
        "results" => [
          %{
            "name" => "github",
            "command_found" => found,
            "missing_env" => ["TOKEN"],
            "dropped" => nil
          }
        ]
      }

      assert {:ok, %Report.McpCheckResult{} = result} = Messages.decode("mcp_check_result", wire)
      assert {:ok, {"mcp_check_result", ^wire}} = Messages.encode(result)

      assert {:error, _} =
               Messages.decode(
                 "mcp_check_result",
                 Map.put(wire, "results", List.duplicate(hd(wire["results"]), 65))
               )

      bad = put_in(wire, ["results", Access.at(0), "command_found"], "maybe")
      assert {:error, _} = Messages.decode("mcp_check_result", bad)
    end
  end
end
