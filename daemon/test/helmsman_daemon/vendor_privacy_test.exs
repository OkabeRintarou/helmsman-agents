defmodule HelmsmanDaemon.VendorPrivacyTest do
  use HelmsmanDaemon.Case
  use Slipstream.SocketTest
  @moduletag :tmp_dir
  import ExUnit.CaptureLog
  import ExUnit.CaptureIO
  alias HelmsmanDaemon.{Connection, Detector}
  alias HelmsmanProtocol.Messages

  defmodule Claude do
    alias HelmsmanDaemon.Adapters.Claude, as: Adapter
    def provider, do: :claude
    def min_version, do: Version.parse!("2.1.0")
    def detect, do: {:ok, %{version: "2.1.0", models: []}}
    def vendor, do: Adapter.vendor()
  end

  defmodule Codex do
    alias HelmsmanDaemon.Adapters.Codex, as: Adapter
    def provider, do: :codex
    def min_version, do: Version.parse!("0.162.0")
    def detect, do: {:ok, %{version: "0.162.1", models: []}}
    def vendor, do: Adapter.vendor()
  end

  test "complete scan and real join/sync carry only keys at debug log level" do
    fixtures!()
    start_execution()
    stop_supervised(Detector)

    log =
      capture_log([level: :debug], fn ->
        start_supervised!({Detector, adapters: [Claude, Codex], detect_interval_ms: 100_000})
        assert [%{vendor: "zai"}, %{vendor: "zhipu"}] = Detector.inventory()
        start_supervised!({HelmsmanDaemon.StatusFile, status_interval_ms: 100_000})
        private_free!(File.read!(HelmsmanDaemon.StatusFile.path()))

        client =
          start_supervised!(
            {Connection,
             test_mode?: true,
             credentials: credentials(),
             heartbeat_interval_ms: 100_000,
             rotation_interval_ms: 100_000}
          )

        accept_connect(client)
        response = %{"daemon_id" => 1, "runtimes" => [], "terminate_run_ids" => []}
        assert_join("daemon:1", join, {:ok, response}, 1_000)

        assert {:ok, %Report.Join{clis: [%{vendor: "zai"}, %{vendor: "zhipu"}]}} =
                 Messages.decode("join", join)

        private_free!(JSON.encode!(join))
        assert_push("daemon:1", "claim", %{}, claim, 1_000)
        reply(client, claim, {:ok, %{"runs" => []}})
        GenServer.cast(client, :sync)
        assert_push("daemon:1", "sync", sync, ref, 1_000)
        private_free!(JSON.encode!(sync))
        reply(client, ref, {:ok, response})
        stop_supervised(Connection)
      end)

    private_free!(log)

    output =
      capture_io(fn ->
        assert HelmsmanDaemon.CLI.run(["runtimes"], adapters: [Claude, Codex]) == 0
      end)

    private_free!(output)
    assert output =~ "claude: 2.1.0 available"
    assert output =~ "codex: 0.162.1 available"
  end

  test "top-level openai endpoint exposes only vendor in a scanned payload" do
    fixtures!()

    File.write!(
      Path.join(System.get_env("CODEX_HOME"), "config.toml"),
      "openai_base_url = \"https://api.deepseek.com/v1?key=SECRET\"\n"
    )

    log =
      capture_log([level: :debug], fn ->
        [cli] = Detector.scan([Codex])
        assert cli.vendor == "deepseek"
        wire = HelmsmanProtocol.CLI.to_wire(cli) |> JSON.encode!()
        private_free!(wire)
        refute wire =~ "api.deepseek.com"
      end)

    private_free!(log)
    refute log =~ "api.deepseek.com"
  end

  test "malformed configuration values never appear in failures or logs" do
    fixtures!()
    File.write!(Path.join(System.get_env("CODEX_HOME"), "config.toml"), "[broken SECRET bigmodel")

    log =
      capture_log([level: :debug], fn ->
        assert [%{vendor: nil, available: true}] = Detector.scan([Codex])
      end)

    private_free!(log)
  end

  defp fixtures! do
    path = Path.join([System.get_env("HOME"), ".claude", "settings.json"])
    File.mkdir_p!(Path.dirname(path))

    File.write!(
      path,
      JSON.encode!(%{
        "env" => %{
          "ANTHROPIC_BASE_URL" => "https://api.z.ai/api/anthropic?k=SECRET",
          "ANTHROPIC_AUTH_TOKEN" => "SECRET"
        }
      })
    )

    File.write!(Path.join(System.get_env("CODEX_HOME"), "config.toml"), """
    model_provider = "glm"
    [model_providers.glm]
    base_url = "https://open.bigmodel.cn/api/paas/v4?key=SECRET"
    """)
  end

  defp private_free!(text) do
    for value <- [
          "SECRET",
          "api.z.ai",
          "bigmodel",
          System.get_env("HOME"),
          System.get_env("CODEX_HOME")
        ] do
      refute text =~ value
    end
  end
end
