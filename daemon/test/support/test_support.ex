defmodule HelmsmanDaemon.TestSupport do
  @moduledoc "Test daemon launch contract for server end-to-end tests."
  alias HelmsmanDaemon.Adapters.Fake
  alias HelmsmanDaemon.{Credentials, Paths}
  def fake_cli, do: Fake.executable()
  def start(opts \\ []), do: HelmsmanDaemon.start_daemon(opts)

  def write_credentials(server_url, daemon_id, token, workspaces \\ []) do
    Credentials.write(%Credentials{
      server_url: server_url,
      daemon_id: daemon_id,
      token: token,
      issued_at: DateTime.utc_now(),
      workspaces: workspaces
    })
  end

  def home, do: Paths.home()
end
