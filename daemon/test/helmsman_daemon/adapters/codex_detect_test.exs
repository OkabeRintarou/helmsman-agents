defmodule HelmsmanDaemon.Adapters.CodexDetectTest do
  use HelmsmanDaemon.Case
  @moduletag :tmp_dir
  alias HelmsmanDaemon.Adapters.Codex

  test "offline detection exposes actual version and supported efforts" do
    assert {:ok, %{version: "0.162.1", models: [], efforts: ~w(low medium high xhigh)}} =
             Codex.detect(fn _ -> {:ok, "codex-cli 0.162.1"} end)

    assert {:error, "codex not found in PATH"} =
             Codex.detect(fn _ -> {:error, "CLI executable not found"} end)

    assert {:error, message} = Codex.detect(fn _ -> {:ok, "codex-cli 0.161.9"} end)
    assert message =~ "0.162.0"
    assert {:error, "Invalid Codex CLI version"} = Codex.detect(fn _ -> {:ok, "unknown"} end)
  end

  test "rejects invalid or conflicting daemon config without exposing its values" do
    home = Paths.private_dir!(Path.join(Paths.home(), "codex"))
    path = Path.join(home, "config.toml")

    for {text, fragment} <- [
          {"[bad", "not valid TOML"},
          {"[mcp_servers.docs]\nurl = \"SECRET\"", "docs"},
          {"project_root_markers = [\"SECRET\"]", "project_root_markers"}
        ] do
      File.write!(path, text)
      assert {:error, message} = Codex.detect(fn _ -> {:ok, "codex-cli 0.162.1"} end)
      assert message =~ fragment
      refute message =~ "SECRET"
    end
  end
end
