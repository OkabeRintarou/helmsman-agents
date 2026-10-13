defmodule HelmsmanDaemon.Adapters.ProviderRealCLITest do
  use HelmsmanDaemon.Case
  @moduletag :real_cli
  @moduletag :tmp_dir
  @moduletag timeout: 120_000
  alias HelmsmanDaemon.Adapters.{Claude, Codex}
  alias HelmsmanDaemon.Adapters.Claude.Provider
  alias HelmsmanDaemon.Adapters.Codex.Config
  alias HelmsmanDaemon.{ProviderHTTP, RunWorker}
  alias HelmsmanProtocol.ProviderAccount

  setup %{tmp_dir: dir} do
    start_execution()
    {account_url, stop_account} = ProviderHTTP.start(self(), :account, "ACCOUNT_SENTINEL")
    {sentinel_url, stop_sentinel} = ProviderHTTP.start(self(), :sentinel, "USER_SENTINEL")
    on_exit(stop_account)
    on_exit(stop_sentinel)
    fake_home = Path.join(dir, "user-home")
    File.mkdir_p!(fake_home)

    env =
      System.get_env()
      |> Map.new(fn {key, _} -> {key, ""} end)
      |> Map.merge(%{
        "PATH" => System.fetch_env!("PATH"),
        "HOME" => fake_home,
        "DISABLE_TELEMETRY" => "1",
        "DISABLE_ERROR_REPORTING" => "1",
        "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC" => "1"
      })

    {:ok, account_url: account_url, sentinel_url: sentinel_url, base_env: env}
  end

  test "real Codex rejects an unbound agent with an empty user home before app-server starts",
       ctx do
    assert {:ok, _} = Codex.detect()
    refute File.exists?(Path.join(Config.home(), "config.toml"))
    refute File.exists?(Path.join(Config.home(), "auth.json"))

    run = spec(1)
    run = %{run | agent: %{run.agent | provider: :codex, custom_args: []}}

    env =
      Map.merge(ctx.base_env, %{
        "CODEX_HOME" => ctx.base_env["HOME"],
        "OPENAI_API_KEY" => "USER_SENTINEL",
        "CODEX_API_KEY" => "USER_SENTINEL",
        "OPENAI_BASE_URL" => ctx.sentinel_url <> "/env/v1"
      })

    worker = launch(run, Codex, env)
    monitor = Process.monitor(worker)

    assert_receive {:report, 1,
                    %Report.Finished{
                      status: :failed,
                      failure_reason: :provider_auth,
                      error: message
                    }, _, _, _},
                   15_000

    assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}, 5_000
    assert message =~ "Bind a provider account"
    assert message =~ Config.home()
    refute_receive {:report, 1, %Report.Started{}, _, _, _}
    refute File.exists?(Path.join(Paths.run(1), "raw.log"))
    refute_receive {:provider_request, _, _}
  end

  test "real Codex rejects undefined user provider before launching", ctx do
    File.write!(Path.join(Config.home(), "config.toml"), ~s(model_provider="undefined"))
    run = spec(1)
    run = %{run | agent: %{run.agent | provider: :codex, custom_args: []}}
    worker = launch(run, Codex, ctx.base_env)
    {finished, _} = collect(1, [])
    assert finished.failure_reason == :provider_auth
    assert finished.error =~ "undefined"
    assert finished.error =~ Config.home()
    eventually(fn -> not Process.alive?(worker) end)
    refute_receive {:report, 1, %Report.Started{}, _, _, _}
    refute File.exists?(Path.join(Paths.run(1), "raw.log"))
    refute_receive {:provider_request, _, _}
  end

  test "real Codex uses user gateway with unused profiles, disables docs and preserves snapshots",
       ctx do
    marker = Path.join(ctx.tmp_dir, "docs-started")
    script = Path.join(ctx.tmp_dir, "docs-cli")
    File.write!(script, "#!/bin/sh\nprintf STARTED > " <> marker <> "\nexit 1\n")
    File.chmod!(script, 0o700)
    home = Config.home()

    File.write!(Path.join(home, "config.toml"), """
    model_provider = "gateway"
    model = "account-model"
    [model_providers.gateway]
    name = "Local fake gateway"
    base_url = "#{ctx.account_url}/account/v1"
    wire_api = "responses"
    env_key = "TEST_GATEWAY_KEY"
    [profiles.work]
    model_provider = "undefined"
    [mcp_servers.docs]
    command = "#{script}"
    [features]
    shell_snapshot = true
    shell_snapshot_v2 = true
    """)

    File.mkdir_p!(Path.join(home, "shell_snapshots"))
    mine = Path.join(home, "shell_snapshots/mine.sh")
    File.write!(mine, "OWNER_SNAPSHOT")
    before = File.stat!(mine, time: :posix)
    assert {:ok, _} = Codex.detect()
    run = bound(:codex, ctx.account_url <> "/account/v1")

    run = %{
      run
      | agent: %{
          run.agent
          | provider_account: nil,
            model: nil,
            custom_args: ["--enable", "shell_snapshot", "--enable", "shell_snapshot_v2"]
        }
    }

    worker = launch(run, Codex, Map.put(ctx.base_env, "TEST_GATEWAY_KEY", "ACCOUNT_SENTINEL"))
    {finished, events} = collect(1, [])
    assert finished.status == :succeeded
    assert finished.summary == "OK"

    assert Enum.any?(
             events,
             &(&1.type == :tool_result and String.contains?(&1.data.output, "SHELL_EXECUTED"))
           )

    refute File.exists?(marker)
    assert File.ls!(Path.join(home, "shell_snapshots")) == ["mine.sh"]
    assert File.read!(mine) == "OWNER_SNAPSHOT"
    assert File.stat!(mine, time: :posix).mtime == before.mtime
    verify_requests()
    verify_cleanup(worker, ctx.tmp_dir)
  end

  test "real Codex refuses top-level legacy profile without exposing values" do
    File.write!(Path.join(Config.home(), "config.toml"), ~s(profile="PROFILE_SENTINEL"))
    assert {:error, message} = Codex.detect()
    assert message =~ "legacy profiles"
    refute message =~ "PROFILE_SENTINEL"
    refute_receive {:provider_request, _, _}
  end

  test "real Claude overrides fake user and project config; only account credentials reach loopback",
       ctx do
    assert {:ok, _} = Claude.detect()
    config_dir = Path.join(ctx.tmp_dir, "fake-claude")
    File.mkdir_p!(config_dir)
    env = Map.new(Provider.cleared(), &{&1, "USER_SENTINEL"})

    env =
      Map.merge(env, %{
        "ANTHROPIC_BASE_URL" => ctx.sentinel_url <> "/user",
        "ANTHROPIC_CUSTOM_HEADERS" => "x-sentinel: USER_SENTINEL"
      })

    env =
      Enum.reduce(
        Enum.filter(Provider.cleared(), &String.starts_with?(&1, "CLAUDE_CODE_USE_")),
        env,
        &Map.put(&2, &1, "1")
      )

    settings = %{"env" => env, "model" => "user-model", "apiKeyHelper" => "printf USER_SENTINEL"}
    File.write!(Path.join(config_dir, "settings.json"), JSON.encode!(settings))

    File.write!(
      Path.join(config_dir, ".credentials.json"),
      JSON.encode!(%{
        "claudeAiOauth" => %{
          "accessToken" => "USER_SENTINEL",
          "refreshToken" => "USER_SENTINEL",
          "expiresAt" => 4_102_444_800_000,
          "scopes" => ["user:inference", "user:profile"]
        }
      })
    )

    File.write!(
      Path.join(ctx.base_env["HOME"], ".claude.json"),
      JSON.encode!(%{
        "hasCompletedOnboarding" => true,
        "oauthAccount" => %{"accountUuid" => "fake", "emailAddress" => "fake@example.test"}
      })
    )

    work = Path.join([Paths.home(), "scratch", "bos", "BOS-1", ".claude"])
    File.mkdir_p!(work)

    for file <- ["settings.json", "settings.local.json"],
        do: File.write!(Path.join(work, file), JSON.encode!(settings))

    run = bound(:claude, ctx.account_url <> "/account")
    run = %{run | agent: %{run.agent | custom_args: ["--max-turns", "3", "--tools", "Bash"]}}
    worker = launch(run, Claude, Map.put(ctx.base_env, "CLAUDE_CONFIG_DIR", config_dir))
    request = claude_messages()
    assert String.starts_with?(request.path, "/account/v1/messages")
    assert request.credentials == %{"authorization" => :account, "x-api-key" => :account}
    assert request.model == "account-model"
    {finished, events} = collect(1, [])
    assert finished.status == :succeeded
    assert finished.summary == "OK"

    assert Enum.any?(
             events,
             &(&1.type == :tool_result and String.contains?(&1.data.output, "SHELL_EXECUTED"))
           )

    verify_requests()
    verify_cleanup(worker, ctx.tmp_dir)
    refute_receive {:provider_request, :sentinel, _}, 200
  end

  test "real Codex selects account despite fake daemon, user and environment providers", ctx do
    File.mkdir_p!(Config.home())

    config =
      "model_provider=\"userprov\"\nmodel=\"user-model\"\n[model_providers.userprov]\nname=\"User sentinel\"\nbase_url=\"#{ctx.sentinel_url}/user/v1\"\nwire_api=\"responses\"\nenv_key=\"USER_KEY\"\n"

    config =
      config <>
        "[profiles.work]\nmodel_provider=\"undefined\"\n[features]\nshell_snapshot=true\nshell_snapshot_v2=true\n"

    File.write!(Path.join(Config.home(), "config.toml"), config)

    File.write!(
      Path.join(Config.home(), "auth.json"),
      JSON.encode!(%{"OPENAI_API_KEY" => "USER_SENTINEL"})
    )

    user_codex = Path.join(ctx.base_env["HOME"], ".codex")
    File.mkdir_p!(user_codex)
    File.write!(Path.join(user_codex, "config.toml"), config)
    assert {:ok, _} = Codex.detect()

    env =
      Map.merge(ctx.base_env, %{
        "USER_KEY" => "USER_SENTINEL",
        "OPENAI_API_KEY" => "USER_SENTINEL",
        "CODEX_API_KEY" => "USER_SENTINEL",
        "OPENAI_BASE_URL" => ctx.sentinel_url <> "/env/v1"
      })

    run = bound(:codex, ctx.account_url <> "/account/v1")

    run = %{
      run
      | agent: %{
          run.agent
          | custom_args: [
              "--enable",
              "shell_snapshot",
              "--enable",
              "shell_snapshot_v2",
              "-c",
              "features.shell_snapshot=true",
              "-c",
              "features={shell_snapshot=true,shell_snapshot_v2=true}"
            ]
        }
    }

    worker = launch(run, Codex, env)
    assert_receive {:provider_request, :account, request}, 60_000
    assert request.path == "/account/v1/responses"
    assert request.credentials == %{"authorization" => :account, "x-api-key" => :absent}
    assert request.model == "account-model"
    {finished, events} = collect(1, [])
    assert finished.status == :succeeded

    assert Enum.any?(
             events,
             &(&1.type == :tool_result and String.contains?(&1.data.output, "SHELL_EXECUTED"))
           )

    verify_requests()
    verify_cleanup(worker, ctx.tmp_dir)
    assert_full_access_reply(1)
    stop_supervised(RunWorker)

    resumed = %{run | run_id: 2, resume_session_id: finished.session_id}
    worker = launch(resumed, Codex, env)
    {resumed_finished, _} = collect(2, [])
    assert resumed_finished.status == :succeeded
    assert resumed_finished.session_id == finished.session_id
    verify_requests()
    verify_cleanup(worker, ctx.tmp_dir, 2)
    assert_full_access_reply(2)
    refute File.exists?(Path.join(Config.home(), "shell_snapshots"))
    refute_receive {:provider_request, :sentinel, _}, 200
  end

  defp verify_requests do
    receive do
      {:provider_request, :account, request} ->
        assert String.starts_with?(request.path, "/account/")
        assert Enum.all?(Map.values(request.credentials), &(&1 in [:account, :absent]))
        verify_requests()

      {:provider_request, :sentinel, _} ->
        flunk("CLI requested the user sentinel provider")
    after
      0 -> :ok
    end
  end

  defp claude_messages do
    receive do
      {:provider_request, :account, %{path: path} = request} ->
        assert String.starts_with?(path, "/account/")
        assert Enum.all?(Map.values(request.credentials), &(&1 in [:account, :absent]))
        if String.starts_with?(path, "/account/v1/messages"), do: request, else: claude_messages()
    after
      60_000 -> flunk("Claude did not call the local messages endpoint")
    end
  end

  defp bound(provider, url) do
    run = spec(1)

    %{
      run
      | prompt: "Reply exactly OK",
        agent: %{
          run.agent
          | provider: provider,
            custom_args: [],
            provider_account: %ProviderAccount{
              base_url: url,
              api_key: "ACCOUNT_SENTINEL",
              models: %{"default" => "account-model"}
            }
        },
        limits: %{run.limits | timeout_ms: 90_000, idle_timeout_ms: 90_000}
    }
  end

  defp launch(run, adapter, env),
    do:
      start_supervised!(
        {RunWorker,
         {run, [adapter: adapter, reporter: TestReporter, base_env: env, kill_timeout_ms: 500]}}
      )

  defp assert_full_access_reply(id) do
    reply =
      Paths.run(id)
      |> Path.join("raw.log")
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.find_value(fn line ->
        case JSON.decode(line) do
          {:ok, %{"id" => 2, "result" => result}} -> result
          _ -> nil
        end
      end)

    assert reply["approvalPolicy"] == "never"
    assert reply["sandbox"] == %{"type" => "dangerFullAccess"}
  end

  defp verify_cleanup(worker, dir, id \\ 1) do
    eventually(fn -> not Process.alive?(worker) end)
    assert File.ls!(Paths.run(id)) == ["raw.log"]

    refute Enum.any?(Path.wildcard(Path.join(dir, "**/*"), match_dot: true), fn path ->
             File.regular?(path) and String.contains?(File.read!(path), "hmr_run_token")
           end)

    for path <- Path.wildcard(Path.join(dir, "**/*"), match_dot: true),
        File.regular?(path),
        do:
          assert(
            not String.contains?(File.read!(path), "ACCOUNT_SENTINEL"),
            "account secret persisted at #{Path.relative_to(path, dir)}"
          )
  end

  defp collect(id, events) do
    receive do
      {:report, ^id, %Report.Events{events: next}, _, _, _} -> collect(id, events ++ next)
      {:report, ^id, %Report.Finished{} = finished, _, _, _} -> {finished, events}
      {:report, ^id, _, _, _, _} -> collect(id, events)
    after
      60_000 -> flunk("local provider CLI did not finish")
    end
  end
end
