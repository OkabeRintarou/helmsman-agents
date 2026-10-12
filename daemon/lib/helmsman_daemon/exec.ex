defmodule HelmsmanDaemon.Exec do
  @moduledoc "Bounded CLI version lookup and operating system process identity."

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
