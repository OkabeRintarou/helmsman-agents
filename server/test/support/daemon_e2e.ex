defmodule Helmsman.DaemonE2E do
  @moduledoc """
  Helpers for end-to-end tests that run the real daemon (`daemon/`,
  `MIX_ENV=test`, its fake CLI adapter) against this server: the endpoint
  on a random port, the daemon's credentials and configuration, the daemon
  as a port, and waiting with its output in failure messages. Commands run
  under a child-subreaper supervisor in isolated process groups so descendants
  that leave the group remain cleanable. The regression cases cover early
  leader exit, port closure, TERM-resistant children, and descendants that
  launch from a non-main thread or appear after the first forced-kill scan.

  These end-to-end tests are Linux-only: the supervisor uses `prctl` and
  `/proc`, and the launcher requires `setsid --fork --wait`.
  """

  use Boundary, top_level?: true, check: [in: false, out: false]

  import ExUnit.Assertions
  import ExUnit.Callbacks, only: [on_exit: 1]

  alias HelmsmanWeb.Endpoint

  @daemon_dir Path.expand("../../../daemon", __DIR__)
  @process_supervisor Path.join(__DIR__, "daemon_process_supervisor.py")
  @output_limit 16_000
  @process_groups_key {__MODULE__, :process_groups}
  @process_group_start_timeout_ms 1_000

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
  `options` contains `:heartbeat_interval_ms`, `:run_worker_opts` and,
  optionally, `:config_check_interval_ms` and `:merge_check_interval_ms`.
  """
  def start_e2e_daemon(home, options, env \\ []) do
    control_dir = Path.join(home, "e2e-control")
    options_path = Path.join(home, "e2e-options.json")
    File.mkdir_p!(control_dir)

    File.write!(
      options_path,
      Jason.encode!(%{
        "heartbeat_interval_ms" => Map.get(options, :heartbeat_interval_ms, 30_000),
        "config_check_interval_ms" => Map.get(options, :config_check_interval_ms),
        "merge_check_interval_ms" => Map.get(options, :merge_check_interval_ms),
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
    # Tests may override HOME for the daemon; keep Mix and Hex where they are
    # installed so `mix` does not ask to install Hex (CI sets neither variable).
    mix_home = System.get_env("MIX_HOME") || Path.join(System.user_home!(), ".mix")
    hex_home = System.get_env("HEX_HOME") || Path.join(System.user_home!(), ".hex")

    start_process(executable, mix_args,
      cd: @daemon_dir,
      env:
        [
          {~c"MIX_ENV", String.to_charlist(mix_env)},
          {~c"HELMSMAN_HOME", String.to_charlist(home)},
          {~c"HELMSMAN_FAKE_CLI", String.to_charlist(fake_cli())},
          {~c"MIX_HOME", String.to_charlist(mix_home)},
          {~c"HEX_HOME", String.to_charlist(hex_home)}
        ] ++ env
    )
  end

  @doc "Starts a test command in an isolated process group and cleans it up when the test exits."
  def start_process(executable, args, options \\ []) do
    setsid = System.find_executable("setsid") || flunk("setsid is required for daemon e2e tests")

    python =
      System.find_executable("python3") || flunk("python3 is required for daemon e2e tests")

    cd = Keyword.fetch!(options, :cd)

    group_file =
      Path.join(
        cd,
        ".helmsman-e2e-pgid-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    cleanup_file = "#{group_file}.cleanup"

    env =
      Keyword.get(options, :env, []) ++
        [
          {~c"HELMSMAN_E2E_PROCESS_GROUP_FILE", String.to_charlist(group_file)},
          {~c"HELMSMAN_E2E_CLEANUP_FILE", String.to_charlist(cleanup_file)}
        ]

    port =
      Port.open({:spawn_executable, setsid}, [
        :binary,
        :exit_status,
        :use_stdio,
        :stderr_to_stdout,
        {:args,
         Enum.map(
           ["--fork", "--wait", python, @process_supervisor, executable | args],
           &String.to_charlist/1
         )},
        {:cd, String.to_charlist(cd)},
        {:env, env}
      ])

    case Port.info(port, :os_pid) do
      {:os_pid, _setsid_pid} ->
        register_process_group_cleanup(
          port,
          group_file,
          cleanup_file,
          Keyword.get(options, :registration_delay_ms, 0)
        )

      nil ->
        cleanup_unregistered_process(port, group_file, cleanup_file)
        File.rm(group_file)
        File.rm(cleanup_file)
        flunk("test command exited before its process id could be registered")
    end

    port
  end

  defp register_process_group_cleanup(port, group_file, cleanup_file, registration_delay_ms) do
    deadline = System.monotonic_time(:millisecond) + @process_group_start_timeout_ms

    if registration_delay_ms > 0, do: Process.sleep(registration_delay_ms)

    case wait_for_process_group_file(group_file, deadline) do
      {:ok, process_group} ->
        process_group = Map.put(process_group, :cleanup_file, cleanup_file)
        register_process_group(port, process_group)

        on_exit(fn ->
          stop_daemon(port)
          File.rm(group_file)
        end)

      :error ->
        cleanup_unregistered_process(port, group_file, cleanup_file)
        File.rm(group_file)
        File.rm(cleanup_file)
        flunk("could not establish daemon process group from #{group_file}")
    end
  end

  defp cleanup_unregistered_process(port, group_file, cleanup_file) do
    case File.read(group_file) do
      {:ok, value} ->
        cleanup_unregistered_descriptor(port, group_file, cleanup_file, value)

      _ ->
        close_port(port)
        raise "could not read unregistered daemon process identity from #{group_file}"
    end
  end

  defp cleanup_unregistered_descriptor(port, group_file, cleanup_file, value) do
    case process_group_descriptor(value) do
      {:ok, process_group} ->
        process_group = Map.put(process_group, :cleanup_file, cleanup_file)
        register_process_group(port, process_group)
        finish_unregistered_cleanup(port, process_group, cleanup_file)

      :error ->
        close_port(port)
        raise "could not establish the identity of unregistered daemon process in #{group_file}"
    end
  end

  defp finish_unregistered_cleanup(port, process_group, cleanup_file) do
    case stop_process_group(process_group) do
      :ok ->
        close_port(port)
        unregister_process_group(port, Map.put(process_group, :port, port))
        File.rm(cleanup_file)
        :ok

      {:error, reason} ->
        raise "could not clean unregistered daemon process: #{inspect(reason)}"
    end
  end

  defp close_port(port) do
    if Port.info(port, :os_pid), do: Port.close(port)
  rescue
    ArgumentError -> :ok
  end

  defp wait_for_process_group_file(path, deadline) do
    if System.monotonic_time(:millisecond) >= deadline do
      :error
    else
      case File.read(path) do
        {:ok, value} ->
          parse_process_group_file(value, path, deadline)

        _ ->
          retry_process_group_file(path, deadline)
      end
    end
  end

  defp parse_process_group_file(value, path, deadline) do
    with {:ok, process_group} <- process_group_descriptor(value),
         true <- process_identity_matches?(process_group) do
      {:ok, process_group}
    else
      _ ->
        retry_process_group_file(path, deadline)
    end
  end

  defp process_group_descriptor(value) do
    case String.split(String.trim(value)) do
      [pid_text, start_time_text] ->
        with {pid, ""} when pid > 0 <- Integer.parse(pid_text),
             {start_time, ""} <- Integer.parse(start_time_text) do
          {:ok, %{pid: pid, start_time: start_time}}
        else
          _ -> :error
        end

      _ ->
        :error
    end
  end

  defp retry_process_group_file(path, deadline) do
    if System.monotonic_time(:millisecond) >= deadline do
      :error
    else
      Process.sleep(10)
      wait_for_process_group_file(path, deadline)
    end
  end

  @doc "Stops the daemon started by `start_daemon/2`."
  def stop_daemon(port) do
    case registered_process_group(port) do
      %{pid: _pid, start_time: _start_time} = process_group ->
        case stop_process_group(process_group) do
          :ok ->
            close_port(port)
            unregister_process_group(port, process_group)
            File.rm(process_group.cleanup_file)
            :ok

          {:error, reason} ->
            raise "could not clean daemon process group #{process_group.pid}: #{inspect(reason)}"
        end

      nil ->
        :ok
    end
  rescue
    ArgumentError -> :ok
  end

  @doc "Stops every registered daemon process group when the test VM exits."
  def stop_all do
    {remaining, failures} =
      registered_process_groups()
      |> Enum.reduce({[], []}, fn process_group, {remaining, failures} ->
        case stop_process_group(process_group) do
          :ok ->
            File.rm(process_group.cleanup_file)
            {remaining, failures}

          {:error, reason} ->
            {[process_group | remaining], [{process_group.pid, reason} | failures]}
        end
      end)

    :persistent_term.put(@process_groups_key, Map.new(remaining, &{&1.port, &1}))

    if failures == [] do
      :ok
    else
      IO.warn("could not confirm cleanup for E2E daemon process groups: #{inspect(failures)}")
      {:error, failures}
    end
  end

  defp stop_process_group(%{pid: process_group_id, cleanup_file: cleanup_file} = process_group) do
    if process_identity_matches?(process_group),
      do: signal_group(process_group_id, "TERM")

    if wait_for_process_group_exit(
         process_group_id,
         System.monotonic_time(:millisecond) + 7_000
       ) do
      wait_for_cleanup_status(cleanup_file, System.monotonic_time(:millisecond) + 1_000)
    else
      {:error, :process_group_exit_timeout}
    end
  end

  defp wait_for_cleanup_status(path, deadline) do
    case File.read(path) do
      {:ok, "ok\n"} ->
        :ok

      {:ok, "ok"} ->
        :ok

      {:ok, status} ->
        if String.starts_with?(status, "error:") do
          {:error, String.trim(status)}
        else
          retry_cleanup_status(path, deadline)
        end

      _ ->
        retry_cleanup_status(path, deadline)
    end
  end

  defp retry_cleanup_status(path, deadline) do
    if System.monotonic_time(:millisecond) >= deadline do
      {:error, :cleanup_status_timeout}
    else
      Process.sleep(10)
      wait_for_cleanup_status(path, deadline)
    end
  end

  defp register_process_group(port, process_group),
    do: update_process_groups(&Map.put(&1, port, Map.put(process_group, :port, port)))

  defp unregister_process_group(port, process_group) do
    update_process_groups(fn process_groups ->
      if Map.get(process_groups, port) == process_group,
        do: Map.delete(process_groups, port),
        else: process_groups
    end)
  end

  defp registered_process_group(port) do
    :global.trans({{__MODULE__, :process_groups}, self()}, fn ->
      :persistent_term.get(@process_groups_key, %{}) |> Map.get(port)
    end)
  end

  defp registered_process_groups do
    :global.trans({{__MODULE__, :process_groups}, self()}, fn ->
      :persistent_term.get(@process_groups_key, %{}) |> Map.values()
    end)
  end

  defp update_process_groups(update) do
    :global.trans({{__MODULE__, :process_groups}, self()}, fn ->
      process_groups = :persistent_term.get(@process_groups_key, %{})
      :persistent_term.put(@process_groups_key, update.(process_groups))
    end)
  end

  defp process_identity_matches?(%{pid: pid, start_time: start_time}) do
    case process_info(pid) do
      %{process_group_id: ^pid, start_time: ^start_time} -> true
      _ -> false
    end
  end

  defp process_info(pid) do
    with {:ok, stat} <- File.read("/proc/#{pid}/stat"),
         {close_paren, 1} <- List.last(:binary.matches(stat, ")")),
         fields <-
           binary_part(stat, close_paren + 2, byte_size(stat) - close_paren - 2) |> String.split(),
         {process_group_id, ""} <- Enum.at(fields, 2) |> Integer.parse(),
         {start_time, ""} <- Enum.at(fields, 19) |> Integer.parse() do
      %{process_group_id: process_group_id, start_time: start_time}
    else
      _ -> nil
    end
  end

  defp wait_for_process_group_exit(process_group_id, deadline) do
    cond do
      not process_group_alive?(process_group_id) ->
        true

      System.monotonic_time(:millisecond) >= deadline ->
        false

      true ->
        Process.sleep(25)
        wait_for_process_group_exit(process_group_id, deadline)
    end
  end

  defp process_group_alive?(process_group_id) do
    case System.cmd("kill", ["-0", "--", "-#{process_group_id}"], stderr_to_stdout: true) do
      {_output, 0} -> true
      _ -> false
    end
  end

  defp signal_group(process_group_id, signal),
    do: System.cmd("kill", ["-#{signal}", "--", "-#{process_group_id}"], stderr_to_stdout: true)

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
