defmodule HelmsmanDaemon.Service.Launchd do
  @moduledoc """
  launchd agent `dev.helmsman.<name>` in the `gui/<uid>` domain.

  The master definition lives in `<home>/service/<label>.plist`; enabling
  copies it to `~/Library/LaunchAgents/` (the only place launchd scans at
  login). `stop` disables the label (persistent across logins), boots it out
  and deletes the LaunchAgents copy, so nothing loads it at the next login
  until `start` / `restart`. Logs are in `<home>/logs/daemon.log` (rotated by
  the daemon); launchd's own output goes to `<home>/logs/launchd.log`.
  """
  @behaviour HelmsmanDaemon.Service
  alias HelmsmanDaemon.{LogFile, Paths, Service}

  @impl true
  def manager, do: "launchd agent"

  def label(ctx), do: "dev.helmsman." <> ctx.name
  def master_path(ctx), do: Path.join([ctx.home, "service", label(ctx) <> ".plist"])

  def agent_path(ctx),
    do: Path.join([ctx.user_home, "Library", "LaunchAgents", label(ctx) <> ".plist"])

  defp launchd_log(ctx), do: Path.join([ctx.home, "logs", "launchd.log"])

  @doc "Property list of the agent."
  def plist(ctx) do
    arguments =
      Enum.map_join(
        [ctx.binary, "daemon", "start", "--foreground", "--service"],
        "\n",
        &"    <string>#{escape(&1)}</string>"
      )

    environment =
      Enum.map_join(Service.environment(ctx), "\n", fn {name, value} ->
        "    <key>#{escape(name)}</key>\n    <string>#{escape(value)}</string>"
      end)

    """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
      <key>Label</key>
      <string>#{escape(label(ctx))}</string>
      <key>ProgramArguments</key>
      <array>
    #{arguments}
      </array>
      <key>RunAtLoad</key>
      <true/>
      <key>KeepAlive</key>
      <dict>
        <key>SuccessfulExit</key>
        <false/>
      </dict>
      <key>ThrottleInterval</key>
      <integer>5</integer>
      <key>EnvironmentVariables</key>
      <dict>
    #{environment}
      </dict>
      <key>StandardOutPath</key>
      <string>#{escape(launchd_log(ctx))}</string>
      <key>StandardErrorPath</key>
      <string>#{escape(launchd_log(ctx))}</string>
    </dict>
    </plist>
    """
  end

  defp escape(value) do
    value
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&apos;")
  end

  defp uid(ctx) do
    ctx.uid || ctx |> Service.run("id", ["-u"]) |> elem(0) |> String.trim()
  end

  defp domain(ctx), do: "gui/#{uid(ctx)}"
  defp target(ctx), do: "#{domain(ctx)}/#{label(ctx)}"

  @impl true
  def available?(ctx) do
    case Service.run(ctx, "launchctl", ["print", domain(ctx)]) do
      {_, 0} ->
        :ok

      _ ->
        {:error,
         "launchd has no GUI session for this user here (log in to the Mac first); " <>
           "run `helmsman daemon start --foreground` under your own supervisor"}
    end
  end

  @impl true
  def installed?(ctx), do: File.exists?(master_path(ctx)) or File.exists?(agent_path(ctx))

  @impl true
  def state(ctx) do
    if installed?(ctx), do: loaded_state(ctx), else: %{state: :not_installed, pid: nil}
  end

  defp disabled?(ctx) do
    case Service.run(ctx, "launchctl", ["print-disabled", domain(ctx)]) do
      {output, 0} ->
        label = Regex.escape(label(ctx))
        {:ok, Regex.match?(~r/"#{label}"\s*=>\s*(true|disabled)/, output)}

      _ ->
        {:error, :unknown}
    end
  end

  defp loaded_state(ctx) do
    case Service.run(ctx, "launchctl", ["print", target(ctx)]) do
      {output, 0} ->
        pid =
          case Regex.run(~r/^\s*pid = (\d+)/m, output) do
            [_, pid] -> String.to_integer(pid)
            _ -> nil
          end

        # Persistent disable does not stop a job whose bootout failed.
        %{state: if(pid, do: :running, else: :enabled_not_running), pid: pid}

      {output, 113} ->
        if String.contains?(output, "Could not find service"),
          do: unloaded_state(ctx),
          else: %{state: :unavailable, pid: nil}

      _ ->
        %{state: :unavailable, pid: nil}
    end
  end

  defp unloaded_state(ctx) do
    case disabled?(ctx) do
      {:ok, disabled?} ->
        state =
          if disabled? or not File.exists?(agent_path(ctx)),
            do: :stopped,
            else: :enabled_not_running

        %{state: state, pid: nil}

      _ ->
        %{state: :unavailable, pid: nil}
    end
  end

  @impl true
  def install(ctx) do
    with :ok <- write_definition(ctx),
         :ok <- Service.run!(ctx, "launchctl", ["enable", target(ctx)]),
         :ok <- unload_existing(ctx) do
      with :ok <- Service.run!(ctx, "launchctl", ["bootstrap", domain(ctx), agent_path(ctx)]) do
        Service.run!(ctx, "launchctl", ["kickstart", "-k", target(ctx)])
      end
    end
  end

  @impl true
  def restart(ctx), do: install(ctx)

  @impl true
  def stop(ctx) do
    disabled = Service.run!(ctx, "launchctl", ["disable", target(ctx)])
    unloaded = bootout(ctx)

    case File.rm(agent_path(ctx)) do
      result when result in [:ok, {:error, :enoent}] ->
        with :ok <- disabled, do: unloaded

      {:error, reason} ->
        {:error, "Could not delete #{agent_path(ctx)}: #{reason}"}
    end
  end

  defp unload_existing(ctx) do
    case Service.run(ctx, "launchctl", ["print", target(ctx)]) do
      {_, 0} ->
        bootout(ctx)

      {output, 113} ->
        if String.contains?(output, "Could not find service"),
          do: :ok,
          else: {:error, "Could not confirm the launchd job state"}

      _ ->
        {:error, "Could not confirm the launchd job state"}
    end
  end

  defp bootout(ctx) do
    case Service.run!(ctx, "launchctl", ["bootout", target(ctx)]) do
      :ok ->
        :ok

      {:error, _} = error ->
        confirm_unloaded(ctx, error)
    end
  end

  defp confirm_unloaded(ctx, error) do
    case Service.run(ctx, "launchctl", ["print", target(ctx)]) do
      {output, 113} ->
        if String.contains?(output, "Could not find service"), do: :ok, else: error

      _ ->
        error
    end
  end

  @impl true
  def after_install(_ctx), do: :ok

  @impl true
  def logs(ctx, lines, follow?) do
    path = LogFile.path()

    if File.exists?(path) do
      args = ["-n", Integer.to_string(lines)] ++ if(follow?, do: ["-F"], else: []) ++ [path]

      case Service.run(ctx, "tail", args, stream: true) do
        {_, 0} -> 0
        _ -> 1
      end
    else
      IO.puts("No daemon log yet at #{path}")
      1
    end
  end

  defp write_definition(ctx) do
    master = master_path(ctx)
    agent = agent_path(ctx)
    Paths.private_dir!(Path.dirname(master))
    Paths.private_dir!(Path.dirname(launchd_log(ctx)))

    with :ok <- File.write(master, plist(ctx)),
         :ok <- File.chmod(master, 0o600),
         :ok <- File.mkdir_p(Path.dirname(agent)),
         :ok <- File.cp(master, agent) do
      File.chmod(agent, 0o644)
    else
      {:error, reason} -> {:error, "Could not write the launchd agent: #{inspect(reason)}"}
    end
  end
end
