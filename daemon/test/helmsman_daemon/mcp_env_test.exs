defmodule HelmsmanDaemon.McpEnvTest do
  use ExUnit.Case, async: true
  alias HelmsmanDaemon.McpEnv

  test "CLI environment scrubs inherited state, agent wins and empty is set" do
    env =
      McpEnv.cli_env(
        %{
          "PATH" => "/bin",
          "A" => "machine",
          "GIT_TOKEN" => "secret",
          "HELMSMAN_RUN_TOKEN" => "token"
        },
        %{"A" => "agent", "EMPTY" => "", "HELMSMAN_RUN_TOKEN" => "override"}
      )

    assert env["A"] == "agent"
    refute Map.has_key?(env, "GIT_TOKEN")
    refute Map.has_key?(env, "HELMSMAN_RUN_TOKEN")
    assert {:ok, "agent"} = McpEnv.expand("${env:A}${env:EMPTY}", env)
  end

  test "nested values substitute once, missing servers warn without leaking values" do
    servers = %{
      "ok" => %{
        "command" => "npx",
        "args" => ["${env:A}"],
        "auth" => %{"header" => "Bearer ${env:A}"}
      },
      "missing" => %{"url" => "https://${env:MISSING}"},
      "reserved" => %{"command" => "${env:HELMSMAN_RUN_TOKEN}"}
    }

    {resolved, warnings} =
      McpEnv.resolve(servers, %{"A" => "canary-${env:INNER}", "HELMSMAN_RUN_TOKEN" => "token"})

    assert resolved["ok"]["args"] == ["canary-${env:INNER}"]
    assert map_size(resolved) == 1
    assert length(warnings) == 2
    refute inspect(warnings) =~ "canary"
    assert inspect(warnings) =~ "MISSING"
  end

  test "without references the JSON is byte-identical" do
    servers = %{
      "old docs" => %{"command" => "npx", "args" => ["${VAR}"], "auth" => %{"secret" => "x"}}
    }

    assert {^servers, []} = McpEnv.resolve(servers, %{})
    {resolved, []} = McpEnv.resolve(servers, %{})
    assert JSON.encode!(resolved) == JSON.encode!(servers)
  end
end
