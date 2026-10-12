defmodule HelmsmanDaemon.Adapters.ClaudePrepareTest do
  use HelmsmanDaemon.Case
  @moduletag :tmp_dir
  alias HelmsmanDaemon.Adapters.Claude

  test "fixed argv, private MCP and valid stream JSON prompt" do
    run = spec(1)

    run = %{
      run
      | agent: %{
          run.agent
          | model: "sonnet",
            effort: "high",
            custom_args: [],
            extra_mcp_servers: %{
              "helmsman" => %{"url" => "wrong"},
              "docs" => %{"type" => "http", "url" => "https://example.test/mcp"}
            }
        },
        resume_session_id: "abc",
        prompt: "引号 \" and newline\n"
    }

    dir = Paths.private_dir!(Paths.run(1))
    work = Path.join(Paths.home(), "scratch")
    assert {:ok, launch} = Claude.prepare(run, dir, work)
    path = Path.join(dir, "mcp.json")

    assert launch.argv == [
             System.find_executable("claude") || "claude",
             "-p",
             "--input-format",
             "stream-json",
             "--output-format",
             "stream-json",
             "--verbose",
             "--permission-mode",
             "bypassPermissions",
             "--strict-mcp-config",
             "--mcp-config",
             path,
             "--model",
             "sonnet",
             "--effort",
             "high",
             "--resume",
             "abc"
           ]

    config = JSON.decode!(File.read!(path))["mcpServers"]

    assert config["helmsman"] == %{
             "type" => "http",
             "url" => run.mcp.url,
             "headers" => %{"Authorization" => "Bearer ${HELMSMAN_RUN_TOKEN}"}
           }

    refute File.read!(path) =~ run.mcp.token
    assert config["docs"] == run.agent.extra_mcp_servers["docs"]
    assert Bitwise.band(File.stat!(path).mode, 0o777) == 0o600
    refute File.exists?(Path.join(work, "mcp.json"))
    assert [{:status, %{level: :warning, message: message}}] = launch.events
    assert message =~ "helmsman"

    assert JSON.decode!(launch.stdin)["message"]["content"] == [
             %{"type" => "text", "text" => run.prompt}
           ]

    refute launch.close_stdin?
  end

  test "absent optional values and all conflicting custom arguments" do
    valued =
      ~w(--output-format --input-format --permission-mode --session-id --model --effort --resume -r)

    switches =
      ~w(-p --print --verbose --dangerously-skip-permissions --strict-mcp-config --continue -c --include-partial-messages --replay-user-messages --no-session-persistence --fork-session)

    dir = Paths.private_dir!(Paths.run(2))
    run = spec(2)

    for flag <- valued ++ switches ++ ["--mcp-config"], equals? <- [false, true] do
      conflicting =
        cond do
          equals? -> [flag <> "=value"]
          flag == "--mcp-config" -> [flag, "a", "b"]
          flag in valued -> [flag, "value"]
          true -> [flag]
        end

      args = ["--add-dir", "/data"] ++ conflicting ++ ["--max-turns", "30"]

      assert {:ok, launch} =
               Claude.prepare(%{run | agent: %{run.agent | custom_args: args}}, dir, dir)

      assert Enum.take(launch.argv, -4) == ["--add-dir", "/data", "--max-turns", "30"]
      refute "--model" in launch.argv
      refute "--effort" in launch.argv
      refute "--resume" in launch.argv
      assert [{:status, %{message: message}}] = launch.events
      assert message =~ flag
    end
  end

  test "resume without value preserves following flag and published example" do
    run = spec(3)
    dir = Paths.private_dir!(Paths.run(3))

    for args <- [
          ["--resume", "--max-turns", "30"],
          ["--add-dir", "/data", "--output-format=text", "--resume", "x", "--max-turns", "30"]
        ] do
      assert {:ok, launch} =
               Claude.prepare(%{run | agent: %{run.agent | custom_args: args}}, dir, dir)

      assert Enum.take(launch.argv, -2) == ["--max-turns", "30"]
      refute "--resume" in launch.argv
    end

    assert {:error, {:workspace_prepare, _}} = Claude.prepare(run, Path.join(dir, "missing"), dir)
  end
end
