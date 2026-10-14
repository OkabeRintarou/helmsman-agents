defmodule HelmsmanDaemon.Service do
  @moduledoc """
  Background service of the installed binary: a systemd user service on Linux
  (`Service.Systemd`), a launchd agent on macOS (`Service.Launchd`).

  The service is named `helmsman-daemon` for the default home `~/.helmsman`, or
  `helmsman-daemon-<first 8 hex of sha256(home)>` for another `HELMSMAN_HOME`,
  which is then passed to the service. Its definition runs
  `<binary> daemon start --foreground --service` with the `PATH` of the shell
  that ran `start` / `restart`.

  System commands go through an injectable executor
  `(program, args, opts) -> {output, exit_status}` (`opts[:stream]` streams the
  output to the terminal): `opts[:cmd]`, else the `:service_cmd` application
  environment, else `system_cmd/3`.
  """
  alias HelmsmanDaemon.{CLI, DiskUsage, Env, EnvFile, Paths, Platform, Release, StatusFile}
  alias HelmsmanDaemon.Service.{Launchd, Systemd}

  @type state :: :not_installed | :stopped | :running | :enabled_not_running | :unavailable
  @type context :: map()

  @callback manager() :: String.t()
  @callback available?(context()) :: :ok | {:error, String.t()}
  @callback installed?(context()) :: boolean()
  @callback state(context()) :: %{state: state(), pid: pos_integer() | nil}
  @callback install(context()) :: :ok | {:error, String.t()}
  @callback restart(context()) :: :ok | {:error, String.t()}
  @callback stop(context()) :: :ok | {:error, String.t()}
  @callback after_install(context()) :: :ok
  @callback logs(context(), pos_integer(), boolean()) :: non_neg_integer()

  @credential_variables ~w(CURSOR_API_KEY COPILOT_GITHUB_TOKEN GH_TOKEN OPENAI_API_KEY ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN)
  @needs_binary "background service needs the installed binary; use --foreground"
  @poll_ms 500

  ## Commands (each returns the exit code)

  def start(opts) do
    ctx = context(opts)

    with :ok <- require_binary(ctx),
         :ok <- CLI.preflight(opts),
         {:ok, impl} <- supported(ctx),
         :ok <- available(ctx, impl) do
      HelmsmanDaemon.security_notice()
      credential_hint()

      case impl.state(ctx) do
        %{state: :running} ->
          IO.puts("already running")
          0

        _ ->
          install(ctx, impl, &impl.install/1)
      end
    end
  end

  def restart(opts) do
    ctx = context(opts)

    with :ok <- require_binary(ctx),
         {:ok, impl} <- supported(ctx),
         :ok <- require_installed(ctx, impl),
         :ok <- available(ctx, impl),
         :ok <- CLI.preflight(opts) do
      credential_hint()
      install(ctx, impl, &impl.restart/1)
    end
  end

  def stop(opts) do
    ctx = context(opts)

    with {:ok, impl} <- supported(ctx, quiet: true),
         true <- impl.installed?(ctx),
         :ok <- available(ctx, impl) do
      stop_service(ctx, impl)
    else
      false -> not_installed()
      {:error, _} -> not_installed()
      code -> code
    end
  end

  @doc "Stops an enabled service before `logout`; `{:error, exit_code}` if that fails."
  def stop_if_enabled(opts) do
    ctx = context(opts)

    with {:ok, impl} <- supported(ctx, quiet: true),
         true <- impl.installed?(ctx),
         :ok <- impl.available?(ctx) do
      stop_before_logout(ctx, impl, impl.state(ctx))
    else
      false -> :ok
      {:error, :unsupported} -> :ok
      {:error, message} -> logout_stop_failure(message)
    end
  end

  defp stop_before_logout(_ctx, _impl, %{state: :stopped}), do: :ok

  defp stop_before_logout(ctx, impl, %{state: state})
       when state in [:running, :enabled_not_running] do
    IO.puts("Stopping the background service before logging out")

    case stop_service(ctx, impl) do
      0 -> :ok
      code -> {:error, code}
    end
  end

  defp stop_before_logout(_ctx, _impl, _info),
    do: logout_stop_failure("Could not confirm the background service state")

  defp logout_stop_failure(message) do
    IO.puts(
      "#{message}; credentials kept. Restore the service manager or stop the service manually before logout"
    )

    {:error, 3}
  end

  def status(opts) do
    ctx = context(opts)
    report(ctx, Keyword.get(opts, :json, false))
  end

  def logs(lines, follow?, opts) do
    ctx = context(opts)

    case supported(ctx) do
      {:ok, impl} -> impl.logs(ctx, lines, follow?)
      code -> code
    end
  end

  ## Context and naming

  def context(opts) do
    platform = Keyword.get_lazy(opts, :platform, &Platform.os/0)
    user_home = Keyword.get_lazy(opts, :user_home, &user_home/0)
    home = Paths.home()
    default? = home == Path.join(user_home, ".helmsman")

    %{
      platform: platform,
      home: home,
      user_home: user_home,
      default_home?: default?,
      name: name(home, default?),
      standalone?: Keyword.get_lazy(opts, :standalone?, &Release.standalone?/0),
      binary: Keyword.get_lazy(opts, :binary, &Release.executable/0),
      path: Keyword.get_lazy(opts, :path, fn -> System.get_env("PATH", "") end),
      cmd: executor(opts),
      uid: Keyword.get(opts, :uid),
      user: Keyword.get(opts, :user),
      sleep: Keyword.get(opts, :sleep, &Process.sleep/1),
      wait_ms: Keyword.get(opts, :wait_ms, 15_000),
      pid_alive?: Keyword.get(opts, :pid_alive?, &StatusFile.helmsman_pid?/1)
    }
  end

  defp user_home, do: System.get_env("HOME") || System.user_home!()

  def name(_home, true), do: "helmsman-daemon"

  def name(home, false) do
    hash = :crypto.hash(:sha256, Path.expand(home)) |> Base.encode16(case: :lower)
    "helmsman-daemon-" <> binary_part(hash, 0, 8)
  end

  @doc "Environment written into the service definition."
  def environment(ctx) do
    [{"PATH", ctx.path}] ++ if(ctx.default_home?, do: [], else: [{"HELMSMAN_HOME", ctx.home}])
  end

  def impl(:linux), do: Systemd
  def impl(:macos), do: Launchd
  def impl(_), do: nil

  ## Executor

  defp executor(opts) do
    case Keyword.get(opts, :cmd) || Application.get_env(:helmsman_daemon, :service_cmd) do
      nil -> &system_cmd/3
      {module, function} -> &apply(module, function, [&1, &2, &3])
      fun when is_function(fun, 3) -> fun
    end
  end

  def system_cmd(program, args, opts) do
    case System.find_executable(program) do
      nil ->
        {"#{program}: command not found\n", 127}

      path ->
        if opts[:stream] do
          {_, status} =
            Env.cmd(path, args, into: IO.stream(:stdio, :line), stderr_to_stdout: true)

          {"", status}
        else
          Env.cmd(path, args, stderr_to_stdout: true)
        end
    end
  end

  @doc "Runs a system command through the context's executor."
  def run(ctx, program, args, opts \\ []), do: ctx.cmd.(program, args, opts)

  @doc "Runs a command that must succeed; `{:error, message}` with its output otherwise."
  def run!(ctx, program, args) do
    case run(ctx, program, args) do
      {_, 0} ->
        :ok

      {output, status} ->
        {:error,
         "`#{Enum.join([program | args], " ")}` failed (#{status}): #{String.trim(output)}"}
    end
  end

  ## Steps

  defp require_binary(%{standalone?: true, binary: binary}) when is_binary(binary), do: :ok

  defp require_binary(_ctx) do
    IO.puts(@needs_binary)
    2
  end

  defp supported(ctx, opts \\ []) do
    case impl(ctx.platform) do
      nil ->
        unless opts[:quiet] do
          IO.puts(
            "background services are supported on Linux (systemd) and macOS (launchd); " <>
              "run `helmsman daemon start --foreground` under your own supervisor"
          )
        end

        if opts[:quiet], do: {:error, :unsupported}, else: 3

      impl ->
        {:ok, impl}
    end
  end

  defp available(ctx, impl) do
    case impl.available?(ctx) do
      :ok ->
        :ok

      {:error, message} ->
        IO.puts(message)
        3
    end
  end

  defp require_installed(ctx, impl) do
    if impl.installed?(ctx) do
      :ok
    else
      IO.puts("not installed; run `helmsman daemon start`")
      3
    end
  end

  defp not_installed do
    IO.puts("not installed")
    0
  end

  defp install(ctx, impl, action) do
    since = DateTime.utc_now() |> DateTime.add(-1) |> DateTime.truncate(:second)

    case action.(ctx) do
      :ok ->
        impl.after_install(ctx)
        await(ctx, impl, since, div(ctx.wait_ms, @poll_ms))
        if report(ctx, false) == 3, do: 1, else: 0

      {:error, message} ->
        IO.puts(message)
        1
    end
  end

  # Waits until the new daemon reports a connection, or its service stops running.
  defp await(_ctx, _impl, _since, 0), do: :ok

  defp await(ctx, impl, since, polls) do
    cond do
      fresh_connected?(since) ->
        :ok

      impl.state(ctx).state in [:not_installed, :stopped] ->
        :ok

      true ->
        ctx.sleep.(@poll_ms)
        await(ctx, impl, since, polls - 1)
    end
  end

  defp fresh_connected?(since) do
    with {:ok, %{"connected" => true, "started_at" => started}} <- StatusFile.read(),
         {:ok, started_at, _} <- DateTime.from_iso8601(started) do
      DateTime.compare(started_at, since) != :lt
    else
      _ -> false
    end
  end

  defp stop_service(ctx, impl) do
    case live_status(ctx) do
      %{"running_runs" => [_ | _] = runs} ->
        count = length(runs)

        IO.puts(
          "#{count} #{if count == 1, do: "run", else: "runs"} will be interrupted; " <>
            "the server retries them per its rules"
        )

      _ ->
        :ok
    end

    case impl.stop(ctx) do
      :ok ->
        IO.puts("Stopped #{ctx.name}; it will not start at login until `helmsman daemon start`")
        0

      {:error, message} ->
        IO.puts(message)
        1
    end
  end

  @doc "Lists credential variables of this shell that the service will not see."
  def credential_hint(env \\ System.get_env()) do
    present = Enum.filter(@credential_variables, &(Map.get(env, &1, "") != ""))

    names =
      case EnvFile.names() do
        {:ok, names} ->
          names

        {:error, :insecure} ->
          IO.puts("#{EnvFile.path()} is ignored until its permissions are 0600")
          []

        _ ->
          []
      end

    case present -- names do
      [] ->
        :ok

      missing ->
        IO.puts(
          "The service does not inherit this shell's #{Enum.join(missing, ", ")}; " <>
            "add them to daemon.env (#{EnvFile.path()}, KEY=VALUE per line, chmod 600)"
        )
    end
  end

  ## Status

  defp live_status(ctx) do
    with {:ok, status} <- StatusFile.read(),
         true <- StatusFile.live?(status, pid_alive?: ctx.pid_alive?) do
      status
    else
      _ -> nil
    end
  end

  defp service_info(ctx) do
    case impl(ctx.platform) do
      nil ->
        %{manager: nil, state: :unsupported, pid: nil}

      impl ->
        info =
          cond do
            not impl.installed?(ctx) -> %{state: :not_installed, pid: nil}
            impl.available?(ctx) != :ok -> %{state: :unavailable, pid: nil}
            true -> impl.state(ctx)
          end

        Map.put(info, :manager, impl.manager())
    end
  end

  defp report(ctx, json?) do
    service = service_info(ctx)
    daemon = live_status(ctx)
    running? = daemon != nil or service.state == :running
    connected? = daemon != nil and daemon["connected"] == true
    disk = DiskUsage.measure(ctx.home)

    if json? do
      IO.puts(
        Jason.encode!(%{
          service: %{
            name: ctx.name,
            manager: service.manager,
            state: service.state,
            pid: service.pid
          },
          running: running?,
          connected: connected?,
          daemon: daemon,
          home: ctx.home,
          disk_usage: Map.new(disk)
        })
      )
    else
      print_status(ctx, service, daemon, disk)
    end

    cond do
      running? and connected? -> 0
      running? -> 1
      true -> 3
    end
  end

  defp print_status(ctx, service, daemon, disk) do
    pid = if service.pid, do: " (pid #{service.pid})", else: ""
    manager = if service.manager, do: ", #{service.manager}", else: ""
    IO.puts("Service: #{state_label(service.state)}#{pid} — #{ctx.name}#{manager}")

    if daemon do
      IO.puts(
        "Daemon: helmsman #{daemon["version"]} (protocol #{daemon["protocol"]}, #{daemon["target"]}), " <>
          "pid #{daemon["pid"]}, started #{daemon["started_at"]}"
      )

      IO.puts("Server: #{daemon["server_url"]} (daemon #{daemon["daemon_id"]})")

      if daemon["connected"] do
        IO.puts(
          "Connected: yes, since #{daemon["connected_at"]}; last message #{daemon["last_message_at"]}"
        )
      else
        IO.puts("Connected: no; last message #{daemon["last_message_at"] || "never"}")
      end

      runs = daemon["running_runs"] || []
      IO.puts("Running runs: #{if runs == [], do: "none", else: Enum.join(runs, ", ")}")
      IO.puts("Credentials: #{daemon["credentials_store"]}")
    else
      IO.puts("Daemon: not running")
    end

    IO.puts(
      "Disk usage: " <>
        Enum.map_join(disk, ", ", fn {name, bytes} -> "#{name}/ #{DiskUsage.format(bytes)}" end)
    )

    IO.puts("Home: #{ctx.home}")
  end

  defp state_label(:not_installed), do: "not installed"
  defp state_label(:stopped), do: "stopped (will not start at login)"
  defp state_label(:running), do: "running"
  defp state_label(:enabled_not_running), do: "enabled but not running"
  defp state_label(:unavailable), do: "unknown (service manager unavailable)"
  defp state_label(:unsupported), do: "not supported on this platform"
end
