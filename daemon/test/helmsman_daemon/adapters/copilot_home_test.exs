defmodule HelmsmanDaemon.Adapters.CopilotHomeTest do
  use HelmsmanDaemon.Case
  @moduletag :tmp_dir
  alias HelmsmanDaemon.Adapters.Copilot
  alias HelmsmanDaemon.Adapters.Copilot.Home

  for name <-
        ~w(mcp-config.json mcp-config mcp-oauth-config hooks agents skills instructions copilot-instructions.md lsp-config.json providers.json permissions-config.json) do
    test "rejects user configuration #{name}" do
      path = Path.join(Paths.copilot_home(), unquote(name))
      File.write!(path, "{}")
      assert {:error, message} = Home.validate()
      assert message =~ unquote(name)

      assert {:error, {:cli_error, ^message}} =
               Copilot.prepare(spec(1), Paths.run(1), Paths.home())

      refute File.exists?(Path.join(Paths.run(1), "mcp.json"))
    end
  end

  test "allows only CLI generated content, empty trust and empty plugins" do
    home = Paths.copilot_home()
    File.mkdir_p!(Path.join(home, "installed-plugins"))
    File.mkdir_p!(Path.join(home, "session-state"))
    File.write!(Path.join(home, "session-store.db"), "")

    File.write!(
      Path.join(home, "config.json"),
      "// User settings belong in settings.json.\n// This file is managed automatically.\n" <>
        ~s({"firstLaunchAt":"today","trustedFolders":[],"hooks":{}})
    )

    assert {:ok, ^home} = Home.validate()
    assert Bitwise.band(File.stat!(home).mode, 0o777) == 0o700
    File.write!(Path.join(home, "installed-plugins/plugin"), "")
    assert {:error, message} = Home.validate()
    assert message =~ "installed-plugins"
  end

  for name <- ~w(config.json settings.json) do
    test "allows generated keys and harmless empty values in #{name}" do
      home = Paths.copilot_home()
      path = Path.join(home, unquote(name))

      for empty <- [nil, false, "", [], %{}] do
        config = %{
          "firstLaunchAt" => "today",
          "trustedFolders" => empty,
          "hooks" => empty,
          "unknownSetting" => empty
        }

        File.write!(path, "// Managed by CLI\n" <> JSON.encode!(config))
        assert {:ok, ^home} = Home.validate()
      end
    end

    test "rejects all non-whitelisted settings in #{name} without exposing values" do
      path = Path.join(Paths.copilot_home(), unquote(name))
      sentinel = "PRIVATE_SETTING_VALUE_SENTINEL"

      for {key, value} <- [
            {"hooks", %{"sessionStart" => [%{"type" => "command", "bash" => sentinel}]}},
            {"statusLine", %{"command" => sentinel}},
            {"trustedFolders", [sentinel]},
            {"allowedUrls", [sentinel]},
            {"defaultPermissionMode", sentinel},
            {"proxyUrl", sentinel},
            {"proxyKerberosServicePrincipal", sentinel},
            {"bashEnv", true},
            {"experimental", true},
            {"unknownSetting", sentinel},
            {"numericSetting", 0}
          ] do
        File.write!(path, JSON.encode!(%{"firstLaunchAt" => "today", key => value}))
        assert {:error, message} = Home.validate()
        assert message =~ unquote(name) <> ": " <> key
        refute message =~ sentinel
        refute message =~ "today"
      end

      for empty <- [nil, false, "", [], %{}] do
        File.write!(path, JSON.encode!(%{"powershellFlags" => empty}))
        assert {:error, message} = Home.validate()
        assert message =~ "powershellFlags"
      end
    end

    test "rejects inline hooks in #{name} without exposing their contents", %{tmp_dir: dir} do
      path = Path.join(Paths.copilot_home(), unquote(name))
      marker = Path.join(dir, "hook-marker")

      for event <- ~w(sessionStart userPromptSubmitted) do
        hooks = %{event => [%{"type" => "command", "bash" => "touch #{marker}"}]}
        File.write!(path, JSON.encode!(%{"hooks" => hooks}))
        assert {:error, message} = Home.validate()
        assert message =~ unquote(name) <> ": hooks"
        refute message =~ "touch"
        refute message =~ marker
        refute File.exists?(marker)
      end
    end

    test "rejects trust and malformed #{name}" do
      path = Path.join(Paths.copilot_home(), unquote(name))

      for contents <- [
            ~s({"trustedFolders":["/work"]}),
            "invalid",
            "[]",
            "null",
            "false",
            "123",
            ~s("scalar"),
            ~s({"firstLaunchAt":"today"} // tail),
            ~s(/* block */ {"firstLaunchAt":"today"})
          ] do
        File.write!(path, contents)
        assert {:error, message} = Home.validate()
        assert message =~ unquote(name)

        assert {:error, {:cli_error, ^message}} =
                 Copilot.prepare(spec(1), Paths.run(1), Paths.home())

        assert {:error, ^message} =
                 Copilot.detect(fn _, _ -> flunk("invalid configuration must not launch") end)
      end
    end
  end
end
