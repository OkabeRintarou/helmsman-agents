defmodule HelmsmanDaemon.Adapters.CursorDetectTest do
  use HelmsmanDaemon.Case
  @moduletag :tmp_dir
  @moduletag :capture_log
  alias HelmsmanDaemon.Adapters.{Cursor, Fake}
  alias HelmsmanDaemon.Adapters.Cursor.Home
  alias HelmsmanDaemon.{Detector, ProcScan}
  @fixtures Path.expand("../../fixtures/cursor", __DIR__)

  setup do
    # Any existing executable stands in for cursor-agent; the runner answers.
    Application.put_env(:helmsman_daemon, :cursor_executable, Fake.executable())
    on_exit(fn -> Application.delete_env(:helmsman_daemon, :cursor_executable) end)
    :ok
  end

  @enabled %{enabled: true, home_links: [".gitconfig"], error: nil}
  @env %{"CURSOR_API_KEY" => "test-key", "CURSOR_CONFIG_DIR" => "/user/config", "PATH" => "/bin"}

  defp fixture(name), do: File.read!(Path.join(@fixtures, name <> ".jsonl"))
  defp stderr(name), do: File.read!(Path.join(@fixtures, name <> ".stderr"))

  defp runner(answers) do
    owner = self()

    fn _path, args, opts ->
      send(owner, {:ran, args, Keyword.put(opts, :listing, File.ls(opts[:cd]))})
      Map.fetch!(answers, args)
    end
  end

  defp answers(overrides \\ %{}) do
    Map.merge(
      %{
        ["--version"] => {:ok, fixture("version")},
        ["mcp", "list"] => {:ok, fixture("mcp_list_empty")},
        ["--list-models"] => {:ok, fixture("list_models")}
      },
      overrides
    )
  end

  defp scratch_left?, do: Path.wildcard(Path.join(Paths.cursor_root(), "detect-*")) != []

  test "off by default: unavailable without running the CLI" do
    assert {:error, reason} = Cursor.detect(Home.configured(nil), @env, runner(answers()))
    assert reason =~ "[cursor] enabled = true"
    assert reason =~ "hooks.json"
    refute_received {:ran, _, _}

    reason = if ProcScan.supported?(), do: reason, else: ProcScan.unsupported_reason()

    assert [%{provider: :cursor, available: false, unavailable_reason: ^reason}] =
             Detector.scan([Cursor])
  end

  test "detection in private directories" do
    assert {:ok, detection} = Cursor.detect(@enabled, @env, runner(answers()))
    assert detection.version == "2026.10.1"
    assert ["auto", "composer-2.5" | _] = detection.models
    assert detection.efforts == []
    refute scratch_left?()

    assert_received {:ran, ["--version"], opts}
    env = Map.new(opts[:env])
    assert env["CURSOR_API_KEY"] == "test-key"
    assert env["HOME"] =~ Paths.cursor_root()
    assert env["CURSOR_CONFIG_DIR"] =~ Paths.cursor_root()
    assert env["AGENT_CLI_CREDENTIAL_STORE"] == "memory"
    assert opts[:timeout] <= 30_000
    assert_received {:ran, ["mcp", "list"], list_opts}
    assert list_opts[:listing] == {:ok, []}
  end

  test "an MCP server from the team makes Cursor unavailable" do
    answers = answers(%{["mcp", "list"] => {:ok, "team-docs: ready\n"}})
    assert {:error, reason} = Cursor.detect(@enabled, @env, runner(answers))
    assert reason =~ "team-docs"
    refute_received {:ran, ["--list-models"], _}
    refute scratch_left?()

    answers = answers(%{["mcp", "list"] => {:ok, fixture("mcp_list_global_vs_project")}})
    assert {:error, reason} = Cursor.detect(@enabled, @env, runner(answers))
    assert reason =~ "helmsman, rogue"
  end

  test "an old version, no API key and a rejected key" do
    old = answers(%{["--version"] => {:ok, "2026.09.30-abc\n"}})

    assert {:error, "Cursor CLI version too old; requires 2026.10.1"} =
             Cursor.detect(@enabled, @env, runner(old))

    assert {:error, reason} =
             Cursor.detect(@enabled, Map.delete(@env, "CURSOR_API_KEY"), runner(answers()))

    assert reason =~ "agent login is not supported"

    rejected =
      answers(%{
        ["--list-models"] => {:error, {{:exit_status, 256}, stderr("error_auth_invalid")}}
      })

    assert {:error, reason} = Cursor.detect(@enabled, @env, runner(rejected))
    assert reason =~ "Cursor rejected CURSOR_API_KEY"
    refute reason =~ "test-key"
    refute scratch_left?()
  end

  test "a timeout leaves Cursor available without models" do
    timeout = answers(%{["--list-models"] => {:error, {:timeout, ""}}})

    assert {:ok, %{version: "2026.10.1", models: []}} =
             Cursor.detect(@enabled, @env, runner(timeout))

    refute scratch_left?()

    slow = fn path, args, opts ->
      if args == ["mcp", "list"],
        do: {:error, {:timeout, ""}},
        else: runner(answers()).(path, args, opts)
    end

    assert {:ok, %{models: []}} = Cursor.detect(@enabled, @env, slow)
    refute scratch_left?()
  end

  test "an invalid link configuration is reported" do
    config = Home.configured(%{"enabled" => true, "home_links" => [".config"]})
    assert {:error, reason} = Cursor.detect(config, @env, runner(answers()))
    assert reason =~ "not allowed"
  end
end
