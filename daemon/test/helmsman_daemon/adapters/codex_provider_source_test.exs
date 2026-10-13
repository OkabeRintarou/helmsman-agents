defmodule HelmsmanDaemon.Adapters.CodexProviderSourceTest do
  use HelmsmanDaemon.Case
  @moduletag :tmp_dir
  alias HelmsmanDaemon.Adapters.Codex.Config
  alias HelmsmanDaemon.{CodexLogin, Env}
  alias HelmsmanProtocol.ProviderAccount

  setup %{tmp_dir: dir} do
    path = CodexLogin.install(dir, "1")
    {:ok, cli: path}
  end

  for {name, file, args, env, login, expected} <- [
        {"empty home", nil, [], %{}, "1", {:error, :none}},
        {"file provider", "gateway", [], %{}, "1", {:ok, :custom_provider}},
        {"argument overrides file", "gateway", ["-c", ~s(model_provider="openai")], %{}, "1",
         {:error, :none}},
        {"login with openai override", "gateway", ["--config=model_provider=\"openai\""], %{},
         "0", {:ok, :login}},
        {"custom argument", "openai", ["--config", ~s(model_provider="gateway")], %{}, "1",
         {:ok, :custom_provider}},
        {"last openai argument", "gateway",
         ["-c", ~s(model_provider="gateway"), "--config", ~s(model_provider="openai")], %{}, "1",
         {:error, :none}},
        {"last custom argument", "openai",
         ["-c=model_provider=\"openai\"", "--config=model_provider=\"gateway\""], %{}, "1",
         {:ok, :custom_provider}},
        {"quoted key", "openai", ["-c", ~s("model_provider"='gateway')], %{}, "1",
         {:ok, :custom_provider}},
        {"CLI raw string fallback", nil, ["-c", "model_provider=gateway"], %{}, "1",
         {:ok, :custom_provider}},
        {"filtered positional argument", nil, [~s(model_provider="gateway")], %{}, "1",
         {:error, :none}},
        {"API environment ignored by built-in provider", "gateway",
         ["-c", ~s(model_provider="openai")],
         %{"OPENAI_API_KEY" => "FAKE", "CODEX_API_KEY" => "FAKE", "OPENAI_BASE_URL" => "FAKE"},
         "1", {:error, :none}},
        {"login", nil, [], %{}, "0", {:ok, :login}},
        {"unexpected exit", nil, [], %{}, "2", {:unknown, {:exit, 2}}}
      ] do
    test name, %{cli: cli} do
      configure(unquote(file))

      run = spec(1)
      run = %{run | agent: %{run.agent | custom_args: unquote(args)}}
      CodexLogin.mode(cli, unquote(login))
      env = Map.merge(Env.child(), unquote(Macro.escape(env)))
      assert Config.provider_source(run, Config.home(), env) == unquote(Macro.escape(expected))

      if unquote(Macro.escape(expected)) == {:ok, :custom_provider},
        do: refute(File.exists?(cli <> ".home")),
        else: assert(File.read!(cli <> ".home") == Config.home())
    end
  end

  defp configure(nil), do: :ok

  defp configure(provider) do
    File.mkdir_p!(Config.home())
    File.write!(Path.join(Config.home(), "config.toml"), "model_provider=\"#{provider}\"")
  end

  test "account bypasses login and conflicting custom arguments", %{cli: cli} do
    run = spec(1)
    account = %ProviderAccount{base_url: "http://localhost/v1", api_key: "FAKE", models: %{}}
    run = %{run | agent: %{run.agent | provider_account: account}}
    assert {:ok, :account} = Config.provider_source(run, Config.home(), %{})
    refute File.exists?(cli <> ".home")
  end

  test "timeout kills the hanging login process and returns only a category", %{cli: cli} do
    CodexLogin.mode(cli, "hang")
    Application.put_env(:helmsman_daemon, :codex_login_timeout_ms, 100)
    assert {:unknown, :timeout} = Config.provider_source(spec(1), Config.home(), Env.child())
    refute alive?(File.read!(cli <> ".pid"))
  end

  test "missing executable and unreadable or invalid config are unknown" do
    Application.put_env(:helmsman_daemon, :codex_executable, "/missing/codex")
    assert {:unknown, :not_found} = Config.provider_source(spec(1), Config.home(), %{})
    File.mkdir_p!(Config.home())
    File.write!(Path.join(Config.home(), "config.toml"), "broken [")
    assert {:unknown, :config} = Config.provider_source(spec(1), Config.home(), %{})
  end
end
