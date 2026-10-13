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
    start_daemon_process(home, env, ["helmsman", "daemon", "start", "--foreground"])
  end

  @doc """
  Starts the daemon through `test/support/e2e_bootstrap.exs`, with test-only
  run options in a JSON file and its file IPC directory shared under `home`.
  `options` contains `:heartbeat_interval_ms` and `:run_worker_opts`.
  """
  def start_e2e_daemon(home, options, env \\ []) do
    control_dir = Path.join(home, "e2e-control")
    options_path = Path.join(home, "e2e-options.json")
    File.mkdir_p!(control_dir)

    File.write!(
      options_path,
      Jason.encode!(%{
        "heartbeat_interval_ms" => Map.get(options, :heartbeat_interval_ms, 30_000),
        "run_worker_opts" =>
          options
          |> Map.get(:run_worker_opts, [])
          |> Map.new(fn {key, value} -> {to_string(key), value} end)
      })
    )

    File.chmod!(options_path, 0o600)

    e2e_env = [
      {~c"HELMSMAN_E2E_OPTIONS", String.to_charlist(options_path)},
      {~c"HELMSMAN_E2E_CONTROL_DIR", String.to_charlist(control_dir)}
    ]

    start_daemon_process(home, env ++ e2e_env, ["run", "test/support/e2e_bootstrap.exs"])
  end

  @doc """
  Starts the real Claude adapter against a test-owned `claude` executable.
  The test-owned executable is selected through `PATH`; the daemon runs in
  dev mode so the provider-account preparation path is exercised end to end.
  """
  def start_provider_daemon(home, env \\ []) do
    start_daemon_process(home, env, ["helmsman", "daemon", "start", "--foreground"], "dev")
  end

  defp start_daemon_process(home, env, mix_args, mix_env \\ "test") do
    executable = System.find_executable("mix") || flunk("mix is required for daemon e2e tests")

    port =
      Port.open({:spawn_executable, executable}, [
        :binary,
        :exit_status,
        :use_stdio,
        :stderr_to_stdout,
        {:args, Enum.map(mix_args, &String.to_charlist/1)},
        {:cd, String.to_charlist(@daemon_dir)},
        {:env,
         [
           {~c"MIX_ENV", String.to_charlist(mix_env)},
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
        signal_group(os_pid, "TERM")

        unless wait_for_port_exit(port, System.monotonic_time(:millisecond) + 5_000) do
          signal_group(os_pid, "KILL")
          _ = wait_for_port_exit(port, System.monotonic_time(:millisecond) + 1_000)
        end

        if Port.info(port, :os_pid), do: Port.close(port)

      nil ->
        :ok
    end
  rescue
    ArgumentError -> :ok
  end

  defp wait_for_port_exit(port, deadline) do
    cond do
      is_nil(Port.info(port, :os_pid)) ->
        true

      System.monotonic_time(:millisecond) >= deadline ->
        false

      true ->
        Process.sleep(25)
        wait_for_port_exit(port, deadline)
    end
  rescue
    ArgumentError -> true
  end

  defp signal_group(os_pid, signal) do
    target = if own_process_group?(os_pid), do: "-#{os_pid}", else: Integer.to_string(os_pid)
    System.cmd("kill", ["-#{signal}", "--", target], stderr_to_stdout: true)
  end

  defp own_process_group?(os_pid) do
    case System.cmd("ps", ["-o", "pgid=", "-p", Integer.to_string(os_pid)],
           stderr_to_stdout: true
         ) do
      {group, 0} -> String.trim(group) == Integer.to_string(os_pid)
      _ -> false
    end
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
