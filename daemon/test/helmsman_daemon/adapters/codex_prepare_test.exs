defmodule HelmsmanDaemon.Adapters.CodexPrepareTest do
  use HelmsmanDaemon.Case
  @moduletag :tmp_dir
  alias HelmsmanDaemon.Adapters.Codex
  alias HelmsmanDaemon.Adapters.Codex.Config
  alias HelmsmanDaemon.{CodexLogin, RunWorker}
  alias HelmsmanProtocol.ProviderAccount

  setup %{tmp_dir: dir} do
    {:ok, cli: CodexLogin.install(dir)}
  end

  test "no source fails with configuration guidance before app-server starts", %{
    tmp_dir: dir,
    cli: cli
  } do
    CodexLogin.mode(cli, "1")
    run = spec(1)
    run = %{run | agent: %{run.agent | name: "m5-codex", custom_args: []}}
    assert {:error, {:provider_auth, message}} = Codex.prepare(run, dir, dir)
    assert message =~ "agent m5-codex"
    assert message =~ "Bind a provider account"
    assert message =~ "CODEX_HOME=#{Config.home()} codex login"
    assert message =~ Path.join(Config.home(), "config.toml")
    refute File.exists?(cli <> ".started")
  end

  test "broken config remains a workspace preparation error without probing login", %{
    tmp_dir: dir,
    cli: cli
  } do
    CodexLogin.mode(cli, "1")
    File.mkdir_p!(Config.home())
    File.write!(Path.join(Config.home(), "config.toml"), "broken [")
    assert {:error, {:workspace_prepare, message}} = Codex.prepare(spec(1), dir, dir)
    assert message =~ "not valid TOML"
    refute File.exists?(cli <> ".home")
    refute File.exists?(cli <> ".started")
  end

  test "account, file provider, arguments and login allow preparation", %{tmp_dir: dir, cli: cli} do
    run = spec(1)
    run = %{run | agent: %{run.agent | custom_args: []}}
    account = %ProviderAccount{base_url: "http://localhost/v1", api_key: "FAKE", models: %{}}
    CodexLogin.mode(cli, "1")

    assert {:ok, _} =
             Codex.prepare(%{run | agent: %{run.agent | provider_account: account}}, dir, dir)

    refute File.exists?(cli <> ".home")

    File.write!(
      Path.join(Config.home(), "config.toml"),
      ~s(model_provider="gateway"\n[model_providers.gateway]\nname="Gateway"\nbase_url="http://localhost/v1")
    )

    assert {:ok, _} = Codex.prepare(run, dir, dir)
    refute File.exists?(cli <> ".home")
    openai = %{run | agent: %{run.agent | custom_args: ["-c", ~s(model_provider="openai")]}}
    assert {:error, {:provider_auth, _}} = Codex.prepare(openai, dir, dir)
    CodexLogin.mode(cli, "0")
    assert {:ok, _} = Codex.prepare(openai, dir, dir)

    File.write!(
      Path.join(Config.home(), "config.toml"),
      ~s(model_provider="openai"\n[model_providers.gateway]\nname="Gateway"\nbase_url="http://localhost/v1")
    )

    CodexLogin.mode(cli, "1")

    custom = %{
      run
      | agent: %{
          run.agent
          | custom_args: [
              "-c",
              ~s(model_provider="openai"),
              "--config",
              ~s(model_provider="gateway")
            ]
        }
    }

    assert {:ok, _} = Codex.prepare(custom, dir, dir)
  end

  test "unknown login starts with a warning containing only its category", %{
    tmp_dir: dir,
    cli: cli
  } do
    for mode <- ["2", "hang"] do
      CodexLogin.mode(cli, mode)
      Application.put_env(:helmsman_daemon, :codex_login_timeout_ms, 100)
      run = spec(1)
      run = %{run | agent: %{run.agent | custom_args: []}}
      assert {:ok, launch} = Codex.prepare(run, dir, dir)
      assert [{:status, %{level: :warning, message: message}}] = launch.events
      assert message =~ "Could not check the Codex login"
      assert message =~ "starting anyway"
      refute message =~ "PRIVATE_LOGIN_OUTPUT"
    end
  end

  test "RunWorker reports failed provider_auth and login sees the actual clean environment", %{
    cli: cli
  } do
    start_execution()
    CodexLogin.mode(cli, "1")
    run = spec(1)

    run = %{
      run
      | agent: %{
          run.agent
          | name: "m5-codex",
            provider: :codex,
            custom_args: [],
            env: %{
              "AGENT_SENTINEL" => "ok",
              "CODEX_HOME" => "/wrong",
              "GIT_SSH_COMMAND" => "explicit",
              "HELMSMAN_SECRET" => "ignored"
            }
        }
    }

    base = %{
      "PATH" => System.fetch_env!("PATH"),
      "GIT_CONFIG_COUNT" => "1",
      "VSCODE_IPC_HOOK_CLI" => "bad",
      "SSH_ASKPASS" => "bad",
      "HELMSMAN_SECRET" => "bad"
    }

    worker =
      start_supervised!(
        {RunWorker, {run, [adapter: Codex, reporter: TestReporter, base_env: base]}}
      )

    monitor = Process.monitor(worker)

    assert_receive {:report, 1,
                    %Report.Finished{
                      status: :failed,
                      failure_reason: :provider_auth,
                      error: message
                    }, _, _, _},
                   3_000

    assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}, 3_000
    assert message =~ Config.home()
    assert File.read!(cli <> ".home") == Config.home()
    names = File.read!(cli <> ".env-names") |> String.split("\n", trim: true)
    assert "AGENT_SENTINEL" in names
    assert "GIT_SSH_COMMAND" in names

    for name <- ~w(GIT_CONFIG_COUNT VSCODE_IPC_HOOK_CLI SSH_ASKPASS HELMSMAN_SECRET),
        do: refute(name in names)

    refute File.exists?(cli <> ".started")
    refute File.exists?(Path.join(Paths.run(1), "raw.log"))
  end

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
