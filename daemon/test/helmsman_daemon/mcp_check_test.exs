defmodule HelmsmanDaemon.McpCheckTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureLog
  alias HelmsmanDaemon.{McpCheck, McpEnv}
  alias HelmsmanProtocol.{McpCheckServer, Push}

  setup do
    dir = Path.join(System.tmp_dir!(), "mcp-check-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    program = Path.join(dir, "canary")
    File.write!(program, "#!/bin/sh\ntouch '#{dir}/executed'\n")
    File.chmod!(program, 0o700)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir, program: program}
  end

  test "agent environment and PATH win; lookup never executes a program", ctx do
    servers = [
      server("found", :stdio, "canary", ["TOKEN"]),
      server("missing", :stdio, "uvx", ["OTHER"]),
      server("remote", :sse, nil, [])
    ]

    request = %Push.McpCheck{
      check_id: "c1",
      runtime_id: 1,
      agent_env: %{"PATH" => ctx.dir, "TOKEN" => "agent-canary"},
      servers: servers
    }

    {result, log} =
      with_log(fn ->
        McpCheck.execute(request, :codex, %{"PATH" => "/bin", "TOKEN" => "machine-canary"})
      end)

    refute log =~ "agent-canary"
    refute log =~ "machine-canary"
    refute log =~ ctx.dir
    assert [found, missing, remote] = result.results
    assert found.command_found == :yes
    assert found.missing_env == []
    assert missing.command_found == :no
    assert missing.missing_env == ["OTHER"]
    assert remote.command_found == :"n/a"
    assert remote.dropped == :unsupported_type
    refute File.exists?(Path.join(ctx.dir, "executed"))
    refute inspect(result) =~ "agent-canary"
    refute inspect(result) =~ ctx.dir
    other = McpCheck.execute(%{request | agent_env: %{"PATH" => ctx.dir}}, :claude, %{})
    assert hd(other.results).missing_env == ["TOKEN"]
    assert hd(other.results).command_found == :yes
  end

  test "absolute referenced command and empty variables agree with runtime resolution", ctx do
    entry = %{"command" => "${env:BIN}", "args" => ["${env:EMPTY}"]}

    request = %Push.McpCheck{
      check_id: "c2",
      runtime_id: 1,
      agent_env: %{"BIN" => ctx.program, "EMPTY" => ""},
      servers: [server("absolute", :stdio, entry["command"], ["BIN", "EMPTY"])]
    }

    {result, log} = with_log(fn -> McpCheck.execute(request, :claude, %{}) end)
    assert [%{command_found: :yes, missing_env: []}] = result.results
    refute log =~ ctx.program
    refute inspect(result) =~ ctx.program

    assert {%{"absolute" => %{"command" => command}}, []} =
             McpEnv.resolve(%{"absolute" => entry}, McpEnv.cli_env(%{}, request.agent_env))

    assert command == ctx.program

    assert [%{command_found: :no, missing_env: ["BIN"]}] =
             McpCheck.execute(%{request | agent_env: %{"EMPTY" => ""}}, :claude, %{}).results
  end

  test "Codex drops a stdio entry with no target" do
    request = %Push.McpCheck{
      check_id: "empty",
      runtime_id: 1,
      agent_env: %{},
      servers: [server("empty", :stdio, nil, [])]
    }

    assert [%{command_found: :no, dropped: :missing_target}] =
             McpCheck.execute(request, :codex, %{}).results
  end

  defp server(name, type, command, refs),
    do: %McpCheckServer{name: name, type: type, command: command, env_refs: refs}
end
