defmodule HelmsmanDaemon.Adapters.CursorHomeTest do
  use HelmsmanDaemon.Case
  @moduletag :tmp_dir
  alias HelmsmanDaemon.Adapters.Cursor
  alias HelmsmanDaemon.Adapters.Cursor.Home

  defp enable(extra \\ "") do
    File.write!(Path.join(Paths.home(), "config.toml"), "[cursor]\nenabled = true\n" <> extra)
  end

  defp cursor_spec(id, extra) do
    run = spec(id)
    %{run | agent: %{run.agent | provider: :cursor, custom_args: [], extra_mcp_servers: extra}}
  end

  defp prepare(run, work_dir) do
    run_dir = Paths.private_dir!(Paths.run(run.run_id))
    Cursor.prepare(run, run_dir, work_dir, %{})
  end

  defp servers(id) do
    [Paths.run(id), "home", ".cursor", "mcp.json"]
    |> Path.join()
    |> File.read!()
    |> JSON.decode!()
    |> Map.fetch!("mcpServers")
  end

  for entry <- [
        ".config",
        ".config/",
        ".cursor",
        ".cursor/hooks.json",
        "./.cursor",
        ".claude",
        ".claude/settings.json",
        ".config/cursor",
        ".config/cursor/auth.json",
        "/etc/passwd",
        "~/.ssh",
        "../x",
        "a/../../x",
        ""
      ] do
    test "home link #{inspect(entry)} makes Cursor unavailable" do
      entry = unquote(entry)
      enable("home_links = [#{JSON.encode!(entry)}]\n")
      assert {:error, reason} = Cursor.detect()
      assert reason =~ "home_links"
      assert {:error, {:cli_error, ^reason}} = prepare(cursor_spec(1, %{}), Paths.home())
    end
  end

  test "allowed links and defaults" do
    for entry <- [".gitconfig", ".cargo", "go", ".config/gh", ".cursorrc-not-cursor"],
        do: assert(Home.link_error(entry) == nil)

    assert Home.configured(nil) == %{enabled: false, home_links: [".gitconfig"], error: nil}
    assert Home.configured(%{"enabled" => "yes"}).error =~ "enabled"
    assert Home.configured(%{"home_links" => ".gitconfig"}).error =~ "home_links"
  end

  test "a non-empty MCP approval in the private data directory stops preparation" do
    enable()
    Home.ensure_dirs!()
    dir = Path.join([Home.data_dir(), "projects", "x"])
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "mcp-approvals.json"), "[]")
    assert {:ok, _} = prepare(cursor_spec(2, %{}), Paths.home())

    File.write!(Path.join(dir, "mcp-approvals.json"), ~s(["helmsman-0123456789abcdef"]))
    assert {:error, {:cli_error, message}} = prepare(cursor_spec(3, %{}), Paths.home())
    assert message =~ "projects/x/mcp-approvals.json"
    refute File.exists?(Path.join(Paths.run(3), "home"))
  end

  test "private HOME with the run's MCP servers, a gitconfig link and nothing else", %{
    tmp_dir: dir
  } do
    enable()
    real_home = System.get_env("HOME")
    File.write!(Path.join(real_home, ".gitconfig"), "[user]\n")
    File.mkdir_p!(Path.join(real_home, ".ssh"))
    work = Path.join(dir, "work")
    File.mkdir_p!(work)

    extra = %{"docs" => %{"url" => "http://docs.invalid/mcp"}, "helmsman" => %{"url" => "x"}}
    assert {:ok, launch} = prepare(cursor_spec(42, extra), work)
    home = Path.join(Paths.run(42), "home")
    path = Path.join([home, ".cursor", "mcp.json"])

    assert File.stat!(path).mode |> Bitwise.band(0o777) == 0o600
    assert File.stat!(home).mode |> Bitwise.band(0o777) == 0o700

    assert %{"helmsman" => helmsman, "docs" => _} = servers(42)
    assert helmsman["url"] == "http://localhost:49999/mcp"
    assert helmsman["headers"]["Authorization"] == "Bearer " <> "${env:HELMSMAN_RUN_TOKEN}"
    refute File.read!(path) =~ "hmr_run_token"
    refute Enum.any?(launch.argv, &(&1 =~ "hmr_run_token"))

    assert {:ok, link} = File.read_link(Path.join(home, ".gitconfig"))
    assert link == Path.join(real_home, ".gitconfig")
    refute File.exists?(Path.join(home, ".ssh"))
    assert File.ls!(work) == []

    assert [{:status, %{level: :warning, message: "Ignored extra MCP server named helmsman"}}] =
             launch.events
  end

  test "interleaved preparations keep each run's own configuration" do
    enable()
    task = fn id, extra -> Task.async(fn -> prepare(cursor_spec(id, extra), Paths.home()) end) end
    first = task.(41, %{"docs" => %{"url" => "http://docs.invalid/mcp"}})
    second = task.(42, %{"wiki" => %{"url" => "http://wiki.invalid/mcp"}})
    assert {:ok, _} = Task.await(first)
    assert {:ok, _} = Task.await(second)

    assert Map.keys(servers(41)) |> Enum.sort() == ["docs", "helmsman"]
    assert Map.keys(servers(42)) |> Enum.sort() == ["helmsman", "wiki"]
    assert servers(41)["helmsman"] == servers(42)["helmsman"]
    assert Path.join(Paths.run(41), "home") != Path.join(Paths.run(42), "home")
  end

  test "private root directories are 0700" do
    enable()
    assert {:ok, _} = prepare(cursor_spec(5, %{}), Paths.home())

    for path <- [Paths.cursor_root(), Home.config_dir(), Home.data_dir()],
        do: assert(Bitwise.band(File.stat!(path).mode, 0o777) == 0o700)
  end
end
