defmodule HelmsmanDaemon.DetectorCodexHintTest do
  use HelmsmanDaemon.Case
  @moduletag :tmp_dir
  import ExUnit.CaptureLog
  alias HelmsmanDaemon.Adapters.Codex
  alias HelmsmanDaemon.Adapters.Codex.Config
  alias HelmsmanDaemon.{CodexLogin, Detector}

  setup %{tmp_dir: dir} do
    {:ok, cli: CodexLogin.install(dir, "1")}
  end

  test "missing source prints once and inventory remains available" do
    output =
      capture_log(fn ->
        start_supervised!({Detector, adapters: [Codex]})

        assert [%{provider: :codex, available: true, unavailable_reason: nil}] =
                 Detector.inventory()

        Detector.refresh()
        assert [%{available: true}] = Detector.inventory()
        send(Process.whereis(Detector), :refresh)
        assert [%{available: true}] = Detector.inventory()
      end)

    assert length(Regex.scan(~r/Codex is installed but not configured/, output)) == 1
    assert output =~ "CODEX_HOME=#{Config.home()} codex login"
    assert output =~ "Codex agents without a provider account will fail"
  end

  test "configured login and custom provider do not print", %{cli: cli} do
    for configured <- [:login, :provider] do
      if configured == :login do
        CodexLogin.mode(cli, "0")
      else
        CodexLogin.mode(cli, "1")
        File.mkdir_p!(Config.home())

        File.write!(
          Path.join(Config.home(), "config.toml"),
          ~s(model_provider="gateway"\n[model_providers.gateway]\nname="Gateway"\nbase_url="http://localhost/v1")
        )
      end

      output =
        capture_log(fn ->
          start_supervised!({Detector, adapters: [Codex]})
          assert [%{available: true}] = Detector.inventory()
          stop_supervised(Detector)
        end)

      refute output =~ "Codex is installed but not configured"
    end
  end

  test "Detector restart in the same daemon startup does not repeat the hint" do
    once = :atomics.new(1, [])

    output =
      capture_log(fn ->
        for _ <- 1..2 do
          start_supervised!({Detector, adapters: [Codex], codex_hint_once: once})
          assert [%{available: true}] = Detector.inventory()
          stop_supervised(Detector)
        end
      end)

    assert length(Regex.scan(~r/Codex is installed but not configured/, output)) == 1
  end

  test "pure scan emits no hint and unknown login is not missing configuration", %{cli: cli} do
    CodexLogin.mode(cli, "2")

    output =
      capture_log(fn ->
        assert [%{available: true}] = Detector.scan([Codex])
        start_supervised!({Detector, adapters: [Codex]})
        assert [%{available: true}] = Detector.inventory()
      end)

    refute output =~ "not configured"
  end
end
