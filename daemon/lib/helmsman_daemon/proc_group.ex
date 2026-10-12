defmodule HelmsmanDaemon.ProcGroup do
  @moduledoc "Process-group continuity based on known member identities, shared by live and recovery cleanup."
  alias HelmsmanDaemon.Exec

  def snapshot(pgid) do
    with {:ok, processes} <- processes() do
      {:ok, for({pid, group, start} <- processes, group == pgid, do: {pid, start})}
    end
  end

  def continuous?(_pgid, known, snapshot), do: Enum.any?(snapshot, &(&1 in known))
  def merge(known, snapshot), do: Enum.uniq(known ++ snapshot)

  def to_wire(members),
    do: Enum.map(members, fn {pid, start} -> %{pid: pid, proc_start: start} end)

  def from_record(%{"members" => members}) when is_list(members) do
    for %{"pid" => pid, "proc_start" => start} <- members,
        is_integer(pid) and pid > 0 and is_binary(start),
        do: {pid, start}
  end

  def from_record(%{"os_pid" => pid, "proc_start" => start})
      when is_integer(pid) and pid > 0 and is_binary(start), do: [{pid, start}]

  def from_record(_), do: []

  def step(pgid, known, signal \\ nil) do
    with {:ok, processes} <- processes() do
      current = for {pid, group, start} <- processes, group == pgid, do: {pid, start}
      alive = Enum.map(processes, fn {pid, _, start} -> {pid, start} end)
      survivors = Enum.filter(known, &(&1 in alive))
      continuous = continuous?(pgid, known, current)
      known = if continuous, do: merge(known, current), else: known

      signal_members(pgid, survivors, continuous, signal)

      {:ok,
       %{
         members: known,
         empty?: current == [] and survivors == [],
         continuous?: continuous,
         unknown?: current != [] and not continuous
       }}
    end
  end

  def kill_group(pgid, known, signal), do: step(pgid, known, signal)

  defp signal_members(_pgid, _members, _continuous, nil), do: :ok
  defp signal_members(pgid, _members, true, signal), do: Exec.signal_group(pgid, signal)

  defp signal_members(_pgid, members, false, signal),
    do: Enum.each(members, fn {pid, _} -> Exec.signal_process(pid, signal) end)

  def recover(pgid, known, opts \\ []) do
    deadline = System.monotonic_time(:millisecond) + Keyword.get(opts, :cleanup_timeout_ms, 5_000)
    recover_until(pgid, known, deadline)
  end

  defp recover_until(pgid, known, deadline) do
    case step(pgid, known, 9) do
      {:ok, %{empty?: true}} -> :ok
      {:ok, %{unknown?: true}} -> {:error, :unrecognized_group}
      {:ok, %{members: members}} -> recover_wait(pgid, members, deadline)
      {:error, _} = error -> error
    end
  end

  defp recover_wait(pgid, members, deadline) do
    if System.monotonic_time(:millisecond) >= deadline do
      {:error, :group_cleanup_timeout}
    else
      Process.sleep(100)
      recover_until(pgid, members, deadline)
    end
  end

  defp processes do
    with {:ok, ps} <- Exec.ps_executable() do
      case System.cmd(ps, ["-A", "-o", "pid=", "-o", "pgid=", "-o", "lstart="],
             stderr_to_stdout: true
           ) do
        {output, 0} -> {:ok, parse(output)}
        _ -> {:error, :process_snapshot_failed}
      end
    end
  end

  defp parse(output) do
    output |> String.split("\n", trim: true) |> Enum.flat_map(&parse_line/1)
  end

  defp parse_line(line) do
    case String.split(String.trim(line), ~r/\s+/, parts: 3) do
      [pid, group, start] -> parse_identity(pid, group, start)
      _ -> []
    end
  end

  defp parse_identity(pid, group, start) do
    with {pid, ""} <- Integer.parse(pid), {group, ""} <- Integer.parse(group) do
      [{pid, group, normalize_start(start)}]
    else
      _ -> []
    end
  end

  def normalize_start(start), do: start |> String.split() |> Enum.join(" ")
end
