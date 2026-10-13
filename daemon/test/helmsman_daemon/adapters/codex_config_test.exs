defmodule HelmsmanDaemon.Adapters.CodexConfigTest do
  use HelmsmanDaemon.Case
  @moduletag :tmp_dir
  alias HelmsmanDaemon.Adapters.Codex
  alias HelmsmanDaemon.Adapters.Codex.Config
  alias HelmsmanDaemon.{CodexLogin, Env}
  setup %{tmp_dir: dir}, do: {:ok, cli: CodexLogin.install(dir, "1")}

  test "providers require exact definitions; builtins and inline tables are supported", %{
    tmp_dir: dir
  } do
    for {args, expected} <- [
          {["-c", ~s(model_provider="gw")], {:error, {:undefined_provider, "gw"}}},
          {["-c", ~s(model_provider="ollama")], {:ok, :builtin_provider}},
          {["-c", ~s(model_provider="lmstudio")], {:ok, :builtin_provider}},
          {["-c", ~s(model_provider="oss")], {:error, {:undefined_provider, "oss"}}},
          {["-c", ~s(model_provider="gw"), "-c", ~s(model_providers.gw2.base_url="SENTINEL")],
           {:error, {:undefined_provider, "gw"}}},
          {[
             "-c",
             ~s(model_provider="gw"),
             "--config",
             ~s("model_providers"."gw".base_url="SENTINEL")
           ], {:ok, :custom_provider}},
          {["-c", ~s(model_provider="gw"), "-c", ~s(model_providers={gw={name="SENTINEL"}})],
           {:ok, :custom_provider}},
          {["-c", ~s(model_provider="gw"), "-c", ~s(model_providers={gw2={name="SENTINEL"}})],
           {:error, {:undefined_provider, "gw"}}}
        ] do
      run = spec(1)
      run = %{run | agent: %{run.agent | custom_args: args}}
      assert Config.provider_source(run, Config.home(), Env.child()) == expected

      case expected do
        {:error, _} ->
          assert {:error, {:provider_auth, message}} = Codex.prepare(run, dir, dir)
          assert message =~ Config.home()
          refute message =~ "SENTINEL"

        _ ->
          assert {:ok, _} = Codex.prepare(run, dir, dir)
      end
    end
  end

  test "env_key is checked against actual environment before requires_openai_auth", %{cli: cli} do
    path = Path.join(Config.home(), "config.toml")
    File.write!(path, ~s(model_provider="gw"\n[model_providers.gw]\nrequires_openai_auth=true))
    run = spec(1)
    assert {:error, :none} = Config.provider_source(run, Config.home(), Env.child())
    CodexLogin.mode(cli, "0")
    assert {:ok, :login} = Config.provider_source(run, Config.home(), Env.child())
    assert File.read!(cli <> ".home") == Config.home()
    File.write!(path, ~s(model_provider="gw"\n[model_providers.gw]\nenv_key="GW_KEY"))

    for env <- [%{}, %{"GW_KEY" => ""}] do
      assert {:error, {:missing_env_key, "gw", "GW_KEY"}} =
               Config.provider_source(run, Config.home(), env)
    end

    assert {:ok, :custom_provider} =
             Config.provider_source(run, Config.home(), %{"GW_KEY" => "SECRET"})

    File.write!(
      path,
      ~s(model_provider="gw"\n[model_providers.gw]\nrequires_openai_auth=true\nenv_key="MISSING")
    )

    assert {:error, {:missing_env_key, "gw", "MISSING"}} =
             Config.provider_source(run, Config.home(), Env.child())
  end

  test "missing environment headers warn only names; unused profiles do not select provider", %{
    tmp_dir: dir
  } do
    File.write!(
      Path.join(Config.home(), "config.toml"),
      ~s(model_provider="gw"\n[model_providers.gw]\nname="Gateway"\nbase_url="http://localhost/v1"\nenv_http_headers={x="HEADER_X",y="HEADER_Y"}\n[profiles.work]\nmodel_provider="other")
    )

    run = spec(1)
    run = %{run | agent: %{run.agent | custom_args: []}}
    assert {:ok, launch} = Codex.prepare(run, dir, dir, %{"HEADER_Y" => "VALUE_SENTINEL"})
    assert [{:status, %{message: message}}] = launch.events
    assert message =~ "HEADER_X"
    refute message =~ "HEADER_Y"
    refute message =~ "VALUE_SENTINEL"
    assert {:ok, :custom_provider} = Config.provider_source(spec(1), Config.home(), %{})
  end

  test "RunWorker checks env_key after reserved daemon environment is stripped", %{
    tmp_dir: dir,
    cli: cli
  } do
    File.write!(
      Path.join(Config.home(), "config.toml"),
      ~s(model_provider="gw"\n[model_providers.gw]\nenv_key="HELMSMAN_PRIVATE_KEY")
    )

    start_execution()
    run = spec(1)

    run = %{
      run
      | agent: %{
          run.agent
          | provider: :codex,
            custom_args: [],
            env: %{"HELMSMAN_PRIVATE_KEY" => "SECRET_SENTINEL"}
        }
    }

    worker =
      start_supervised!(
        {HelmsmanDaemon.RunWorker,
         {run,
          [
            adapter: Codex,
            reporter: TestReporter,
            base_env: %{"HELMSMAN_PRIVATE_KEY" => "SECRET_SENTINEL"}
          ]}}
      )

    assert_receive {:report, 1, %Report.Finished{failure_reason: :provider_auth, error: message},
                    _, _, _},
                   3_000

    assert message =~ "HELMSMAN_PRIVATE_KEY"
    refute message =~ "SECRET_SENTINEL"
    eventually(fn -> not Process.alive?(worker) end)
    refute File.exists?(cli <> ".started")
    refute File.exists?(Path.join(Paths.run(1), "raw.log"))
    refute_receive {:report, 1, %Report.Started{}, _, _, _}
    assert File.dir?(dir)
  end

  test "source check sees the final injected run environment", %{cli: cli} do
    File.write!(
      Path.join(Config.home(), "config.toml"),
      ~s(model_provider="gw"\n[model_providers.gw]\nenv_key="HELMSMAN_RUN_ID")
    )

    start_execution()
    run = spec(1)

    worker =
      start_supervised!(
        {HelmsmanDaemon.RunWorker, {run, [adapter: Codex, reporter: TestReporter, base_env: %{}]}}
      )

    assert_receive {:report, 1, %Report.Started{session_id: nil}, _, _, _}, 3_000
    assert_receive {:report, 1, %Report.Finished{failure_reason: :cli_error}, _, _, _}, 3_000
    eventually(fn -> not Process.alive?(worker) end)
    assert File.exists?(cli <> ".started")
  end

  test "env_key CODEX_HOME is checked using the selected launch home", %{tmp_dir: dir} do
    File.write!(
      Path.join(Config.home(), "config.toml"),
      ~s(model_provider="gw"\n[model_providers.gw]\nenv_key="CODEX_HOME")
    )

    run = spec(1)
    assert {:ok, launch} = Codex.prepare(run, dir, dir, %{})
    assert launch.env == [{"CODEX_HOME", Config.home()}]
  end

  test "profile flags are filtered for bound and unbound agents" do
    for bound? <- [false, true],
        key <- ["profile", "profiles", "profiles.work.model_provider"],
        args <- [["-c", key <> "=VALUE_SENTINEL"], ["--config=" <> key <> "=VALUE_SENTINEL"]] do
      assert {[], [^key]} = Config.filter(args, bound?)
    end

    assert {[], ["--profile"]} = Config.filter(["--profile", "work"])
  end
end
