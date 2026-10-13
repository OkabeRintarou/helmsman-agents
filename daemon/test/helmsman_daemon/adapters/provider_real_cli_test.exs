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

    config = config <> "[features]\nshell_snapshot=true\nshell_snapshot_v2=true\n"
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
