defmodule Helmsman.DaemonE2E do
  @moduledoc """
  Helpers for end-to-end tests that run the real daemon (`daemon/`,
  `MIX_ENV=test`, its fake CLI adapter) against this server: the endpoint
  on a random port, the daemon's credentials and configuration, the daemon
  as a port, and waiting with its output in failure messages.
  """

  use Boundary, top_level?: true, check: [in: false, out: false]

  import ExUnit.Assertions
  import ExUnit.Callbacks, only: [on_exit: 1]

  alias HelmsmanWeb.Endpoint

  @daemon_dir Path.expand("../../../daemon", __DIR__)
  @output_limit 16_000

  @doc "The daemon project's directory."
  def daemon_dir, do: @daemon_dir

  @doc "The fake CLI of the daemon's tests."
  def fake_cli, do: Path.join(@daemon_dir, "test/support/fake_cli/fake-cli")

  @doc """
  Restarts the endpoint as a server on a random local port until the test
  exits; returns its base URL.
  """
  def start_endpoint do
    previous = Application.fetch_env!(:helmsman, Endpoint)
    :ok = Supervisor.terminate_child(Helmsman.Supervisor, Endpoint)

    Application.put_env(
      :helmsman,
      Endpoint,
      Keyword.merge(previous, server: true, http: [ip: {127, 0, 0, 1}, port: 0])
    )

    assert {:ok, _pid} = Supervisor.restart_child(Helmsman.Supervisor, Endpoint)

    on_exit(fn ->
      :ok = Supervisor.terminate_child(Helmsman.Supervisor, Endpoint)
      Application.put_env(:helmsman, Endpoint, previous)
      {:ok, _pid} = Supervisor.restart_child(Helmsman.Supervisor, Endpoint)
    end)

    {:ok, {{127, 0, 0, 1}, port}} = Endpoint.server_info(:http)
    "http://127.0.0.1:#{port}"
  end

  @doc "Writes the daemon's `config.toml` and `credentials` into `home`."
  def write_credentials(home, server_url, daemon_id, token) do
    File.mkdir_p!(home)

    File.write!(
      Path.join(home, "config.toml"),
      "server_url = \"#{server_url}\"\nlog_level = \"debug\"\n"
    )

    path = Path.join(home, "credentials")

    File.write!(
      path,
      Jason.encode!(%{
        server_url: server_url,
        daemon_id: daemon_id,
        token: token,
        issued_at: DateTime.to_iso8601(DateTime.utc_now(:second)),
        workspaces: []
      })
    )

    File.chmod!(path, 0o600)
  end

  @doc """
  Starts `mix helmsman daemon start --foreground` in `daemon/` with
  `HELMSMAN_HOME=home` and `env` (charlist pairs); closed when the test
  exits.
  """
  def start_daemon(home, env \\ []) do
    {executable, args} =
      case System.find_executable("mise") do
        nil ->
          mix = System.find_executable("mix") || flunk("mix is required for daemon e2e tests")
          {mix, ["helmsman", "daemon", "start", "--foreground"]}

        mise ->
          {mise, ["exec", "--", "mix", "helmsman", "daemon", "start", "--foreground"]}
      end

    port =
      Port.open({:spawn_executable, executable}, [
        :binary,
        :exit_status,
        :use_stdio,
        :stderr_to_stdout,
        {:args, Enum.map(args, &String.to_charlist/1)},
        {:cd, String.to_charlist(@daemon_dir)},
        {:env,
         [
           {~c"MIX_ENV", ~c"test"},
           {~c"HELMSMAN_HOME", String.to_charlist(home)},
           {~c"HELMSMAN_FAKE_CLI", String.to_charlist(fake_cli())}
         ] ++ env}
      ])

    on_exit(fn -> stop_daemon(port) end)
    port
  end

  @doc "Stops the daemon started by `start_daemon/2`."
  def stop_daemon(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, os_pid} ->
        Port.close(port)
        System.cmd("kill", ["-TERM", Integer.to_string(os_pid)], stderr_to_stdout: true)

      nil ->
        :ok
    end
  rescue
    ArgumentError -> :ok
  end

  @doc """
  Waits until `fun` returns a truthy value (returned), failing with the
  daemon's output after `timeout` or when it exits.
  """
  def wait_until(port, label, fun, timeout \\ 60_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    wait_loop(port, label, fun, deadline)
  end

  defp wait_loop(port, label, fun, deadline) do
    drain(port)

    cond do
      result = fun.() ->
        result

      System.monotonic_time(:millisecond) >= deadline ->
        label = if is_function(label, 0), do: label.(), else: label
        flunk("timed out waiting for #{label}; daemon output:\n#{output(port)}")

      true ->
        assert_alive!(port)
        Process.sleep(50)
        wait_loop(port, label, fun, deadline)
    end
  end

  defp assert_alive!(port) do
    receive do
      {^port, {:exit_status, status}} ->
        flunk("daemon exited with status #{status}; daemon output:\n#{output(port)}")
    after
      0 -> :ok
    end
  end

  defp drain(port) do
    receive do
      {^port, {:data, data}} ->
        key = {__MODULE__, port}
        combined = IO.iodata_to_binary([Process.get(key, <<>>), data])
        size = byte_size(combined)

        Process.put(
          key,
          if(size > @output_limit,
            do: binary_part(combined, size - @output_limit, @output_limit),
            else: combined
          )
        )

        drain(port)
    after
      0 -> :ok
    end
  end

  @doc "The daemon's output so far (the last 16 KB)."
  def output(port) do
    drain(port)
    Process.get({__MODULE__, port}, "<no daemon output>")
  end
end
