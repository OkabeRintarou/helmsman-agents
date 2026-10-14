defmodule HelmsmanDaemon.Service.Systemd do
  @moduledoc """
  systemd user service `~/.config/systemd/user/<name>.service`.

  `start` writes the unit, reloads and `enable --now`s it; `stop` is
  `disable --now` (the unit file stays, nothing starts it at login or boot);
  `restart` rewrites the unit, reloads, enables and restarts it. Logs are read
  from journald.
  """
  @behaviour HelmsmanDaemon.Service
  alias HelmsmanDaemon.Service

  @unavailable "systemd user services are not available here; " <>
                 "run `helmsman daemon start --foreground` under your own supervisor"

  @impl true
  def manager, do: "systemd user service"

  def unit_name(ctx), do: ctx.name <> ".service"
  def unit_path(ctx), do: Path.join([ctx.user_home, ".config", "systemd", "user", unit_name(ctx)])

  @doc "Unit file contents."
  def unit(ctx) do
    environment =
      Enum.map_join(Service.environment(ctx), "\n", fn {name, value} ->
        "Environment=" <> quoted("#{name}=#{value}", false)
      end)

    """
    [Unit]
    Description=Helmsman agent daemon

    [Service]
    Type=simple
    ExecStart=#{quoted(ctx.binary, true)} daemon start --foreground --service
    Restart=on-failure
    RestartSec=5
    TimeoutStopSec=60
    KillMode=mixed
    #{environment}

    [Install]
    WantedBy=default.target
    """
  end

  # Double-quoted unit value: backslash escapes, `%` specifiers and, in command
  # lines, `$` variable expansion are neutralised.
  defp quoted(value, command?) do
    escaped =
      value
      |> String.replace("\\", "\\\\")
      |> String.replace("\"", "\\\"")
      |> String.replace("%", "%%")

    escaped = if command?, do: String.replace(escaped, "$", "$$"), else: escaped
    "\"" <> escaped <> "\""
  end

  @impl true
  def available?(ctx) do
    case systemctl(ctx, ["show", "--property=Version"]) do
      {_, 0} -> :ok
      _ -> {:error, @unavailable}
    end
  end

  @impl true
  def installed?(ctx), do: File.regular?(unit_path(ctx))

  @impl true
  def state(ctx) do
    if installed?(ctx) do
      installed_state(ctx)
    else
      %{state: :not_installed, pid: nil}
    end
  end

  defp installed_state(ctx) do
    with {:ok, enabled?} <- enabled(ctx),
         {:ok, active?} <- active(ctx) do
      cond do
        active? -> %{state: :running, pid: main_pid(ctx)}
        enabled? -> %{state: :enabled_not_running, pid: nil}
        true -> %{state: :stopped, pid: nil}
      end
    else
      _ -> %{state: :unavailable, pid: nil}
    end
  end

  defp enabled(ctx) do
    case systemctl(ctx, ["is-enabled", unit_name(ctx)]) do
      {"enabled\n", 0} -> {:ok, true}
      {"disabled\n", 1} -> {:ok, false}
      _ -> {:error, :unknown}
    end
  end

  defp active(ctx) do
    case systemctl(ctx, ["is-active", unit_name(ctx)]) do
      {"active\n", 0} -> {:ok, true}
      {output, 3} when output in ["inactive\n", "failed\n"] -> {:ok, false}
      _ -> {:error, :unknown}
    end
  end

  defp main_pid(ctx) do
    case Integer.parse(output(ctx, ["show", "--property=MainPID", "--value", unit_name(ctx)])) do
      {pid, ""} when pid > 0 -> pid
      _ -> nil
    end
  end

  @impl true
  def install(ctx) do
    with :ok <- write_unit(ctx),
         :ok <- systemctl!(ctx, ["daemon-reload"]) do
      systemctl!(ctx, ["enable", "--now", unit_name(ctx)])
    end
  end

  @impl true
  def restart(ctx) do
    with :ok <- write_unit(ctx),
         :ok <- systemctl!(ctx, ["daemon-reload"]),
         :ok <- systemctl!(ctx, ["enable", unit_name(ctx)]) do
      systemctl!(ctx, ["restart", unit_name(ctx)])
    end
  end

  @impl true
  def stop(ctx), do: systemctl!(ctx, ["disable", "--now", unit_name(ctx)])

  @impl true
  def after_install(ctx) do
    user = ctx.user || System.get_env("USER") || output(ctx, "id", ["-un"])

    case Service.run(ctx, "loginctl", ["show-user", user, "--property=Linger"]) do
      {output, 0} ->
        if String.trim(output) == "Linger=no" do
          IO.puts(
            "the daemon stops when you log out; run `sudo loginctl enable-linger $USER` to keep it running"
          )
        end

      _ ->
        :ok
    end

    :ok
  end

  @impl true
  def logs(ctx, lines, follow?) do
    args = ["--user", "-u", unit_name(ctx), "-o", "cat", "-n", Integer.to_string(lines)]
    args = if follow?, do: args ++ ["-f"], else: args

    case Service.run(ctx, "journalctl", args, stream: true) do
      {_, 0} -> 0
      _ -> 1
    end
  end

  defp write_unit(ctx) do
    path = unit_path(ctx)

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(path, unit(ctx)) do
      File.chmod(path, 0o644)
    else
      {:error, reason} -> {:error, "Could not write #{path}: #{:file.format_error(reason)}"}
    end
  end

  defp systemctl(ctx, args), do: Service.run(ctx, "systemctl", ["--user" | args])
  defp systemctl!(ctx, args), do: Service.run!(ctx, "systemctl", ["--user" | args])
  defp output(ctx, args), do: output(ctx, "systemctl", ["--user" | args])

  defp output(ctx, program, args),
    do: ctx |> Service.run(program, args) |> elem(0) |> String.trim()
end
