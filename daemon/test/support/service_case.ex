defmodule HelmsmanDaemon.ServiceCase do
  @moduledoc "Helpers for background service tests: fake service managers and status.json."
  alias HelmsmanDaemon.{FakeServiceManager, Paths, StatusFile}

  @binary "/opt/helmsman/bin/helmsman"
  @path "/usr/local/bin:/usr/bin:/bin"

  def binary, do: @binary
  def path, do: @path
  def user_home, do: System.get_env("HOME")

  @doc "Uses `<HOME>/.helmsman` as the daemon home (the default service name)."
  def default_home! do
    home = Path.join(user_home(), ".helmsman")
    System.put_env("HELMSMAN_HOME", home)
    Paths.ensure!()
    home
  end

  def service_opts(fake, platform, extra \\ []) do
    Keyword.merge(
      [
        platform: platform,
        standalone?: true,
        binary: @binary,
        path: @path,
        user_home: user_home(),
        user: "tester",
        uid: "501",
        cmd: FakeServiceManager.cmd(fake),
        sleep: fn _ -> :ok end,
        wait_ms: 1_000,
        pid_alive?: fn _ -> false end
      ],
      extra
    )
  end

  @doc "Writes status.json as a running daemon would."
  def write_status(fields \\ %{}) do
    now = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    status =
      Map.merge(
        %{
          "pid" => 4242,
          "version" => "0.11.0",
          "protocol" => HelmsmanProtocol.version(),
          "target" => "linux-x64",
          "server_url" => "https://hm.example.test",
          "daemon_id" => 42,
          "connected" => true,
          "connected_at" => now,
          "last_message_at" => now,
          "running_runs" => [],
          "credentials_store" => "file",
          "started_at" => now,
          "updated_at" => now
        },
        fields
      )

    File.write!(StatusFile.path(), Jason.encode!(status))
    File.chmod!(StatusFile.path(), 0o600)
    status
  end

  @doc "Sleep callback that makes the started daemon report a connection."
  def connects(fields \\ %{}), do: fn _ -> write_status(fields) end
end
