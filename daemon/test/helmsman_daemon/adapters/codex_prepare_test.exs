defmodule HelmsmanDaemon.Adapters.CodexPrepareTest do
  use HelmsmanDaemon.Case
  @moduletag :tmp_dir
  alias HelmsmanDaemon.Adapters.Codex
  alias HelmsmanDaemon.Adapters.Codex.Config

  test "pipeline handshake, MCP, optional model and resumed thread", %{tmp_dir: dir} do
    run = spec(1)
    run = %{run | agent: %{run.agent | model: "gpt-5", effort: "high", custom_args: []}}

    for resume <- [nil, "t-1"] do
      assert {:ok, launch} = Codex.prepare(%{run | resume_session_id: resume}, dir, dir)
      assert launch.env == [{"CODEX_HOME", Path.join(dir, "codex")}]
      refute launch.close_stdin?

      frames =
        launch.stdin
        |> IO.iodata_to_binary()
        |> String.split("\n", trim: true)
        |> Enum.map(&JSON.decode!/1)

      assert Enum.map(frames, & &1["method"]) == [
               "initialize",
               "initialized",
               if(resume, do: "thread/resume", else: "thread/start")
             ]

      assert Enum.all?(frames, &(&1["jsonrpc"] == "2.0"))
      params = List.last(frames)["params"]
      assert params["cwd"] == dir
      assert params["model"] == "gpt-5"
      assert params["approvalPolicy"] == "never"
      assert params["sandbox"] == "danger-full-access"

      assert params["config"]["mcp_servers"]["helmsman"] == %{
               "url" => run.mcp.url,
               "bearer_token_env_var" => "HELMSMAN_RUN_TOKEN"
             }

      assert params["threadId"] == resume
      refute inspect(launch) =~ run.mcp.token
      assert File.ls!(Config.home()) == []
    end

    assert {:ok, launch} = Codex.prepare(spec(1), dir, dir)
    refute IO.iodata_to_binary(launch.stdin) =~ "\"model\""
  end

  test "extra MCP conversion, reserved name casefolding and warnings", %{tmp_dir: dir} do
    run = spec(1)

    extra = %{
      "docs" => %{
        "command" => "docs",
        "args" => ["serve"],
        "env" => %{"KEY" => "SECRET"},
        "cwd" => dir
      },
      "remote" => %{
        "type" => "http",
        "url" => "http://example.test",
        "headers" => %{"Key" => "SECRET"}
      },
      "urlonly" => %{"url" => "http://example.test"},
      "old" => %{"type" => "sse", "url" => "SECRET"},
      "invalid" => %{},
      "Helmsman" => %{"command" => "SECRET"}
    }

    run = %{run | agent: %{run.agent | extra_mcp_servers: extra, custom_args: []}}
    {servers, removed} = Config.mcp(run)
    assert removed == ["Helmsman", "invalid", "old"]
    assert servers["docs"] == extra["docs"]
    assert servers["remote"]["http_headers"] == %{"Key" => "SECRET"}
    assert servers["urlonly"] == %{"url" => "http://example.test"}
    assert {:ok, launch} = Codex.prepare(run, dir, dir)
    refute inspect(launch.events) =~ "SECRET"
  end

  test "custom arguments use a whitelist and report names without values" do
    blocked =
      ~w(mcp_servers approval_policy approvals_reviewer sandbox_mode sandbox_workspace_write model model_reasoning_effort project_root_markers projects)

    for key <- blocked do
      assert {[], [^key]} = Config.filter(["-c", key <> "=SECRET"])
      nested = key <> ".nested"
      assert {[], [^nested]} = Config.filter(["--config=" <> nested <> "=SECRET"])
      assert {[], [^nested]} = Config.filter(["--config", "\"#{key}\".nested=SECRET"])
    end

    for flag <- ["-c", "--config", "--enable", "--disable"] do
      value = if flag in ["-c", "--config"], do: "model_provider=\"gw\"", else: "foo"
      assert {[^flag, ^value], []} = Config.filter([flag, value])
      inline = flag <> "=" <> value
      assert {[^inline], []} = Config.filter([inline])
    end

    args = [
      "-c",
      "model_provider=\"gw\"",
      "--config=mcp_servers.x.url=\"u\"",
      "--listen",
      "ws://0.0.0.0:1",
      "--enable",
      "foo",
      "-c",
      "sandbox_mode=\"read-only\""
    ]

    assert {kept, removed} = Config.filter(args)
    assert kept == ["-c", "model_provider=\"gw\"", "--enable", "foo"]
    assert removed == ["mcp_servers.x.url", "--listen", "sandbox_mode"]
    refute inspect(removed) =~ "ws://"
  end
end
