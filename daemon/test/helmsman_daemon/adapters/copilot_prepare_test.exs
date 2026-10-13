defmodule HelmsmanDaemon.Adapters.CopilotPrepareTest do
  use HelmsmanDaemon.Case
  @moduletag :tmp_dir
  alias HelmsmanDaemon.Adapters.Copilot

  for name <- ~w(config.json settings.json) do
    test "rejects other user settings and accepts CLI-generated #{name}" do
      path = Path.join(Paths.copilot_home(), unquote(name))
      sentinel = "PRIVATE_SETTING_VALUE_SENTINEL"

      File.write!(
        path,
        JSON.encode!(%{
          "firstLaunchAt" => "today",
          "statusLine" => %{"command" => sentinel},
          "allowedUrls" => [sentinel],
          "unknownSetting" => sentinel
        })
      )

      assert {:error, {:cli_error, message}} =
               Copilot.prepare(spec(1), Paths.run(1), Paths.home())

      for key <- ~w(statusLine allowedUrls unknownSetting), do: assert(message =~ key)
      refute message =~ sentinel
      refute File.exists?(Paths.run(1))

      File.write!(
        path,
        "// Managed by CLI\n// CLI state\n" <>
          JSON.encode!(%{"firstLaunchAt" => "today", "trustedFolders" => [], "hooks" => %{}})
      )

      assert {:ok, _} = Copilot.prepare(spec(1), Paths.run(1), Paths.home())
    end

    test "checks #{name} inline hooks on every prepare", %{tmp_dir: dir} do
      assert {:ok, _} = Copilot.prepare(spec(1), Paths.run(1), Paths.home())
      marker = Path.join(dir, "hook-marker")
      hooks = %{"sessionStart" => [%{"type" => "command", "bash" => "touch #{marker}"}]}

      File.write!(
        Path.join(Paths.copilot_home(), unquote(name)),
        JSON.encode!(%{"hooks" => hooks})
      )

      for run <- [spec(2), %{spec(3) | resume_session_id: "existing-session"}] do
        assert {:error, {:cli_error, message}} =
                 Copilot.prepare(run, Paths.run(run.run_id), Paths.home())

        assert message =~ unquote(name) <> ": hooks"
        refute message =~ marker
        refute File.exists?(Paths.run(run.run_id))
        refute File.exists?(marker)
      end
    end
  end

  test "argv snapshot, private MCP without token and stdin supports long prompts" do
    run = spec(1)

    run = %{
      run
      | prompt: String.duplicate("x", 200_000),
        agent: %{
          run.agent
          | custom_args: [],
            model: "gpt-5-mini",
            effort: "low",
            extra_mcp_servers: %{
              "helmsman" => %{"url" => "rogue"},
              "extra" => %{"command" => "tool"}
            }
        }
    }

    assert {:ok, launch} = Copilot.prepare(run, Paths.run(1), Paths.home())
    [exe | args] = launch.argv
    assert exe == (System.find_executable(Copilot.executable()) || Copilot.executable())
    id = Enum.at(args, 8)

    assert Regex.match?(
             ~r/^[a-f0-9]{8}-[a-f0-9]{4}-4[a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12}$/,
             id
           )

    assert args == [
             "--output-format",
             "json",
             "--allow-all",
             "--no-ask-user",
             "--disable-builtin-mcps",
             "--additional-mcp-config",
             "@" <> Path.join(Paths.run(1), "mcp.json"),
             "--session-id",
             id,
             "--model",
             "gpt-5-mini",
             "--reasoning-effort",
             "low",
             "--no-auto-update",
             "--log-dir",
             Path.join(Paths.run(1), "copilot-logs")
           ]

    assert launch.stdin == run.prompt
    assert launch.close_stdin?
    refute run.prompt in launch.argv
    text = File.read!(Path.join(Paths.run(1), "mcp.json"))
    refute String.contains?(text, run.mcp.token)
    assert String.contains?(text, "${HELMSMAN_RUN_TOKEN}")
    config = JSON.decode!(text)["mcpServers"]
    assert config["helmsman"]["url"] == run.mcp.url
    assert config["helmsman"]["tools"] == ["*"]
    assert config["extra"] == %{"command" => "tool", "disableToolCache" => true}
    assert Bitwise.band(File.stat!(Path.join(Paths.run(1), "mcp.json")).mode, 0o777) == 0o600
    assert Enum.any?(launch.events, fn {:status, event} -> event.message =~ "helmsman" end)
    assert Copilot.init_state(run, launch).session_id == id
  end

  test "resume uses existing id with no implicit new session" do
    run = spec(2)
    run = %{run | resume_session_id: "existing", agent: %{run.agent | custom_args: []}}
    assert {:ok, launch} = Copilot.prepare(run, Paths.run(2), Paths.home())
    assert ["--resume", "existing"] == Enum.slice(launch.argv, 8, 2)
    refute "--session-id" in launch.argv
    refute "--model" in launch.argv
    assert Copilot.init_state(run, launch).session_id == "existing"
  end
end
