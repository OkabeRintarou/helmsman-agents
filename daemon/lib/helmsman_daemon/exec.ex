defmodule HelmsmanDaemon.Exec do
  @moduledoc "Bounded CLI version lookup and operating system process identity."

  require Logger
  alias HelmsmanDaemon.{ProcGroup, RepoCache}

  @doc "Launch a CLI with a lock pin retained until its process group is empty."
  def start_cli(argv, options, opts \\ []) do
    caller = self()
    ref = make_ref()
    locks = RepoCache.command_locks()

    {guardian, monitor} =
      spawn_monitor(fn -> cli_owner(caller, ref, locks, argv, options, opts) end)

    receive do
      {^ref, {:ok, exec_pid, os_pid}} ->
        Process.demonitor(monitor, [:flush])
        {:ok, exec_pid, os_pid, guardian}

      {^ref, error} ->
        Process.demonitor(monitor, [:flush])
        error

      {:DOWN, ^monitor, :process, ^guardian, _} ->
        {:error, :cli_guardian_exited}
    end
  end

  def release_cli(nil), do: :ok

  def release_cli(guardian) do
    monitor = Process.monitor(guardian)
    send(guardian, :release_cli)

    receive do
      {:DOWN, ^monitor, :process, ^guardian, _} -> :ok
    end
  end

  defp cli_owner(caller, ref, locks, argv, options, opts) do
    owner = Process.monitor(caller)
    if callback = Keyword.get(opts, :before_cli_lock), do: callback.()

    result =
      RepoCache.with_command_locks(locks, fn ->
        if Process.alive?(caller),
          do: launch_cli(caller, ref, owner, argv, options, opts),
          else: {:error, :owner_down}
      end)

    send(caller, {ref, result})
  end

  defp launch_cli(caller, ref, owner, argv, options, opts) do
    case :exec.run(argv, options) do
      {:ok, exec_pid, os_pid} ->
        {:ok, members} = ProcGroup.snapshot(os_pid)

        try do
          send(caller, {ref, {:ok, exec_pid, os_pid}})
          await_cli(caller, owner, exec_pid, os_pid, members, opts)
        after
          cleanup_command(os_pid, Process.get({__MODULE__, :cli_members}, members))
        end

      error ->
        error
    end
  end

  defp await_cli(caller, owner, exec_pid, os_pid, members, opts) do
    receive do
      {:DOWN, _, :process, ^exec_pid, _} = message ->
        members = final_cli_members(os_pid, members)
        Process.put({__MODULE__, :cli_members}, members)
        send(caller, message)
        await_cli(caller, owner, exec_pid, os_pid, members, opts)

      {:DOWN, ^owner, :process, _, _} ->
        if callback = Keyword.get(opts, :before_cli_cleanup), do: callback.()
        :ok

      :release_cli ->
        :ok
    end
  end

  defp final_cli_members(os_pid, members) do
    case ProcGroup.snapshot(os_pid) do
      {:ok, current} -> ProcGroup.merge(members, current)
      _ -> members
    end
  end

  @doc "Run a bounded command in its own group, tied to the caller's lifetime."
  def command(argv, opts \\ []) do
    caller = self()
    ref = make_ref()
    locks = RepoCache.command_locks()
    {pid, monitor} = spawn_monitor(fn -> command_owner(caller, ref, argv, opts, locks) end)

    receive do
      {^ref, result} ->
        Process.demonitor(monitor, [:flush])
        result

      {:DOWN, ^monitor, :process, ^pid, _reason} ->
        {:error, {:launch, "command supervisor exited"}}
    end
  end

  defp command_owner(caller, ref, argv, opts, locks) do
    owner = Process.monitor(caller)
    if callback = Keyword.get(opts, :before_lock), do: callback.()

    result =
      RepoCache.with_command_locks(locks, fn ->
        receive do
          {:DOWN, ^owner, :process, _, _} ->
            {:error, {:owner_down, "caller exited before launch"}}
        after
          0 ->
            if Process.alive?(caller),
              do: run_command(owner, argv, opts),
              else: {:error, {:owner_down, "caller exited before launch"}}
        end
      end)

    send(caller, {ref, result})
  end

  defp run_command(owner, argv, opts) do
    options = [:stdout, :stderr, :monitor, {:group, 0}, :kill_group, {:kill_timeout, 0}]
    options = options ++ Keyword.take(opts, [:cd, :env])

    case :exec.run(argv, options) do
      {:ok, exec_pid, os_pid} ->
        members =
          case ProcGroup.snapshot(os_pid) do
            {:ok, members} -> members
            _ -> []
          end

        try do
          notify_start(opts, os_pid)
          deadline = System.monotonic_time(:millisecond) + Keyword.get(opts, :timeout, 30_000)
          collect_command(exec_pid, os_pid, owner, "", deadline)
        after
          cleanup_command(os_pid, members)
        end

      _ ->
        {:error, {:launch, "command could not be started"}}
    end
  end

  defp cleanup_command(os_pid, members) do
    ProcGroup.step(os_pid, members, 9)
    cleanup_command(os_pid, members, System.monotonic_time(:millisecond) + 30_000)
  end

  defp cleanup_command(os_pid, members, warn_at) do
    members =
      case ProcGroup.step(os_pid, members, 9) do
        {:ok, group} -> group.members
        _ -> members
      end

    case ProcGroup.live_snapshot(os_pid) do
      {:ok, []} ->
        :ok

      _ ->
        next_warning = cleanup_warning(os_pid, warn_at)
        Process.sleep(100)
        cleanup_command(os_pid, members, next_warning)
    end
  end

  defp cleanup_warning(os_pid, warn_at) do
    now = System.monotonic_time(:millisecond)

    if now >= warn_at do
      Logger.warning(
        "Git process group #{os_pid} cleanup is still pending; resource locks retained"
      )

      now + 30_000
    else
      warn_at
    end
  end

  defp notify_start(opts, os_pid) do
    if callback = Keyword.get(opts, :on_start), do: callback.(os_pid)
  end

  defp collect_command(exec_pid, os_pid, owner, output, deadline) do
    receive do
      {stream, ^os_pid, data} when stream in [:stdout, :stderr] ->
        collect_output(exec_pid, os_pid, owner, output, data, deadline)

      {:DOWN, _, :process, ^exec_pid, :normal} ->
        {:ok, output}

      {:DOWN, _, :process, ^exec_pid, reason} ->
        {:error, {reason, output}}

      {:DOWN, ^owner, :process, _, _} ->
        stop_command(exec_pid, os_pid)
        {:error, {:owner_down, output}}
    after
      max(deadline - System.monotonic_time(:millisecond), 0) ->
        stop_command(exec_pid, os_pid)
        {:error, {:timeout, output}}
    end
  end

  defp collect_output(exec_pid, os_pid, owner, output, data, deadline) do
    if byte_size(output) + byte_size(data) > 1_048_576 do
      stop_command(exec_pid, os_pid)
      {:error, {:output_limit, output}}
    else
      collect_command(exec_pid, os_pid, owner, output <> data, deadline)
    end
  end

  defp stop_command(exec_pid, os_pid) do
    signal_group(os_pid, 9)

    receive do
      {:DOWN, _, :process, ^exec_pid, _} -> :ok
    after
      5_000 -> :ok
    end
  end

  def version(executable, opts \\ []) do
    case System.find_executable(executable) do
      nil ->
        {:error, "CLI executable not found"}

      path ->
        probe(path, Keyword.get(opts, :args, ["--version"]), Keyword.get(opts, :timeout, 10_000))
    end
  end

  defp probe(path, args, timeout) do
    case :exec.run([path | args], [:stdout, :stderr, :monitor, {:group, 0}, :kill_group]) do
      {:ok, exec_pid, os_pid} ->
        collect_version(exec_pid, os_pid, "", System.monotonic_time(:millisecond) + timeout)

      _ ->
        {:error, "CLI version command failed"}
    end
  end

  defp collect_version(exec_pid, os_pid, output, deadline) do
    receive do
      {stream, ^os_pid, data} when stream in [:stdout, :stderr] ->
        if byte_size(output) + byte_size(data) > 65_536 do
          signal_group(os_pid, 9)
          {:error, "CLI version output too large"}
        else
          collect_version(exec_pid, os_pid, output <> data, deadline)
        end

      {:DOWN, _, :process, ^exec_pid, :normal} ->
        {:ok, String.trim(output)}

      {:DOWN, _, :process, ^exec_pid, _} ->
        {:error, "CLI version command failed"}
    after
      max(deadline - System.monotonic_time(:millisecond), 0) ->
        signal_group(os_pid, 9)
        {:error, "CLI version command timed out"}
    end
  end

  def resolve_kill do
    case System.find_executable("kill") do
      nil ->
        {:error, :kill_missing}

      path ->
        :persistent_term.put({__MODULE__, :kill}, Path.expand(path))
        {:ok, path}
    end
  end

  def signal_group(pgid, signal) when is_integer(pgid) and pgid > 0 and signal in [9, 15] do
    case kill_executable() do
      {:ok, path} ->
        case System.cmd(path, ["-#{signal}", "--", "-#{pgid}"], stderr_to_stdout: true) do
          {_, 0} -> :ok
          _ -> {:error, :not_found}
        end

      error ->
        error
    end
  end

  defp kill_executable do
    case :persistent_term.get({__MODULE__, :kill}, nil) do
      nil -> resolve_kill()
      path -> {:ok, path}
    end
  end

  def resolve_ps do
    case System.find_executable("ps") do
      nil ->
        {:error, :ps_missing}

      path ->
        :persistent_term.put({__MODULE__, :ps}, Path.expand(path))
        {:ok, path}
    end
  end

  def ps_executable do
    case :persistent_term.get({__MODULE__, :ps}, nil) do
      nil -> resolve_ps()
      path -> {:ok, path}
    end
  end

  def signal_process(pid, signal) when is_integer(pid) and pid > 0 and signal in [9, 15] do
    with {:ok, path} <- kill_executable() do
      case System.cmd(path, ["-#{signal}", "--", "#{pid}"], stderr_to_stdout: true) do
        {_, 0} -> :ok
        _ -> {:error, :not_found}
      end
    end
  end

  def proc_start(pid) when is_integer(pid) and pid > 0 do
    {:ok, ps} = ps_executable()

    case System.cmd(ps, ["-o", "lstart=", "-p", Integer.to_string(pid)]) do
      {value, 0} -> {:ok, HelmsmanDaemon.ProcGroup.normalize_start(value)}
      _ -> {:error, :not_found}
    end
  end
end
