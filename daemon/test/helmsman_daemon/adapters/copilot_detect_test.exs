defmodule HelmsmanDaemon.Adapters.CopilotDetectTest do
  use HelmsmanDaemon.Case
  @moduletag :tmp_dir
  alias HelmsmanDaemon.Adapters.Copilot
  alias HelmsmanDaemon.Adapters.Copilot.Probe
  @fixtures Path.expand("../../fixtures/copilot", __DIR__)

  for name <- ~w(config.json settings.json) do
    test "rejects other user settings and detects CLI-generated #{name}" do
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

      assert {:error, message} = Copilot.detect(fn _, _ -> flunk("must not launch") end)
      for key <- ~w(statusLine allowedUrls unknownSetting), do: assert(message =~ key)
      refute message =~ sentinel

      File.write!(
        path,
        "// Managed by CLI\n// CLI state\n" <>
          JSON.encode!(%{"firstLaunchAt" => "today", "trustedFolders" => [], "hooks" => %{}})
      )

      assert {:ok, %{version: "1.0.96", models: models}} =
               Copilot.detect(fn argv, _ ->
                 stdout = if "--version" in argv, do: "1.0.96", else: acp("acp_newonly_free")
                 {:ok, %{stdout: stdout, stderr: "", status: 0}}
               end)

      assert "gpt-5-mini" in models
    end

    test "rejects #{name} inline hooks before version or ACP commands", %{tmp_dir: dir} do
      marker = Path.join(dir, "hook-marker")
      hooks = %{"sessionStart" => [%{"type" => "command", "bash" => "touch #{marker}"}]}

      File.write!(
        Path.join(Paths.copilot_home(), unquote(name)),
        JSON.encode!(%{"hooks" => hooks})
      )

      assert {:error, message} =
               Copilot.detect(fn _, _ -> flunk("inline hooks must not launch CLI commands") end)

      assert message =~ unquote(name) <> ": hooks"
      refute message =~ marker
      refute File.exists?(marker)
      assert File.ls!(Paths.home()) |> Enum.all?(&(not String.starts_with?(&1, "copilot-probe")))
    end
  end

  defp acp(name) do
    @fixtures
    |> Path.join(name <> ".jsonl")
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(&JSON.decode!/1)
    |> Enum.filter(&(&1["dir"] == "<-"))
    |> Enum.map_join("\n", &JSON.encode!(&1["msg"]))
  end

  test "version, login and model detection replay with explicit isolated argv and cleanup" do
    owner = self()

    executor = fn argv, opts ->
      root = Path.dirname(opts[:env]["COPILOT_HOME"])
      send(owner, {:root, root})
      assert opts[:env]["COPILOT_HOME"] == Path.join(root, "home")

      assert Enum.take(argv, -2) == ["--log-dir", Path.join(root, "logs")] or
               "--disable-builtin-mcps" == List.last(argv)

      assert Path.join(root, "logs") in argv
      assert File.exists?(root)

      stdout =
        if "--version" in argv, do: "GitHub Copilot CLI 1.0.96.", else: acp("acp_newonly_free")

      if "--acp" in argv do
        assert "--disable-builtin-mcps" in argv
        assert "--no-auto-update" in argv
        assert opts[:timeout] == 20_000
      end

      {:ok, %{stdout: stdout, stderr: "", status: 0}}
    end

    assert {:ok, info} = Copilot.detect(executor)
    assert info.version == "1.0.96"
    assert "gpt-5-mini" in info.models
    assert info.efforts == ~w(low medium high xhigh max)
    assert_receive {:root, root}
    refute File.exists?(root)
    assert File.ls!(Paths.copilot_home()) == []
  end

  for result <- [:not_logged_in, :timeout, :failure] do
    test "cleans after #{result}" do
      owner = self()

      executor = fn argv, opts ->
        send(owner, {:root, Path.dirname(opts[:env]["COPILOT_HOME"])})

        if "--version" in argv do
          {:ok, %{stdout: "1.0.96", stderr: "", status: 0}}
        else
          case unquote(result) do
            :not_logged_in -> {:ok, %{stdout: acp("acp_not_logged_in"), stderr: "", status: 0}}
            other -> {:error, other}
          end
        end
      end

      result = Copilot.detect(executor)

      if unquote(result) == :not_logged_in do
        assert {:error, message} = result
        assert message =~ "gh auth login"
      else
        assert {:ok, %{models: []}} = result
      end

      assert_receive {:root, root}
      refute File.exists?(root)
    end
  end

  test "old, invalid and missing versions, contaminated home are unavailable" do
    for text <- ["1.0.80", "unknown"] do
      assert {:error, _} =
               Copilot.detect(fn _, _ -> {:ok, %{stdout: text, stderr: "", status: 0}} end)
    end

    assert {:error, _} = Copilot.detect(fn _, _ -> {:error, :launch} end)
    File.write!(Path.join(Paths.copilot_home(), "mcp-config.json"), "{}")
    assert {:error, message} = Copilot.detect(fn _, _ -> flunk("must not launch") end)
    assert message =~ "mcp-config.json"
  end

  test "ACP timeout sends SIGTERM to its own group", %{tmp_dir: dir} do
    cli = Path.join(dir, "timeout-cli")
    marker = Path.join(dir, "term")

    File.write!(
      cli,
      "#!/bin/sh\ntrap 'printf term > #{marker}; exit 0' TERM\nwhile :; do sleep 0.05; done\n"
    )

    File.chmod!(cli, 0o700)
    owner = self()

    assert {:error, :timeout} =
             Probe.command([cli],
               env: HelmsmanDaemon.Env.child(),
               cd: dir,
               timeout: 100,
               acp: true,
               on_start: fn pid -> send(owner, {:pid, pid}) end
             )

    assert File.read!(marker) == "term"
    assert_receive {:pid, pid}
    assert {:ok, []} = HelmsmanDaemon.ProcGroup.live_snapshot(pid)
  end
end
