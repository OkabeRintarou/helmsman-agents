defmodule HelmsmanDaemon.ProcGroup do
  @moduledoc "Process-group continuity based on known member identities, shared by live and recovery cleanup."
  require Logger
  alias HelmsmanDaemon.{Env, Exec, ProcScan}

  def snapshot(pgid) do
    with {:ok, processes} <- processes() do
      {:ok, for({pid, group, start} <- processes, group == pgid, do: {pid, start})}
    end
  end

  @doc "Group snapshot excluding zombies, which cannot perform repository writes."
  def live_snapshot(pgid) do
    with {:ok, ps} <- Exec.ps_executable() do
      case Env.cmd(ps, ["-A", "-o", "pid=", "-o", "pgid=", "-o", "stat=", "-o", "lstart="],
             stderr_to_stdout: true
           ) do
        {output, 0} -> {:ok, parse_live(output, pgid)}
        _ -> {:error, :process_snapshot_failed}
      end
    end
  end

  defp parse_live(output, pgid) do
    output
    |> String.split("\n", trim: true)
    |> Enum.flat_map(&parse_live_line(&1, pgid))
  end

  defp parse_live_line(line, pgid) do
    case String.split(String.trim(line), ~r/\s+/, parts: 4) do
      [pid, group, status, start] -> live_identity(pid, group, status, start, pgid)
      _ -> []
    end
  end

  defp live_identity(pid, group, status, start, pgid) do
    if String.starts_with?(status, "Z") do
      []
    else
      for {member, ^pgid, identity} <- parse_identity(pid, group, start), do: {member, identity}
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
      when is_integer(pid) and pid > 0 and is_binary(start),
      do: [{pid, start}]

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

  @doc """
  `step/3` that also covers the descendants carrying the launch's tag
  (`add-cursor-adapter` decision 10). Tagged processes and unknown ones
  linked to members join `members` and are signalled one by one; uncertain
  processes are never signalled, but `empty?` stays false while any lives.
  `settled?` ignores them (crash recovery only warns about them).
  """
  def step(pgid, known, signal, nil), do: step(pgid, known, signal)

  def step(pgid, known, signal, tracking) do
    with {:ok, processes} <- processes(),
         {:ok, infos, own} <- ProcScan.scan(tracking) do
      starts = Map.new(processes, fn {pid, _, start} -> {pid, start} end)
      current = for {pid, group, start} <- processes, group == pgid, do: {pid, start}
      continuous = not is_nil(pgid) and continuous?(pgid, known, current)
      alive = Enum.filter(known, &alive?(&1, starts))
      known = if continuous, do: merge(known, current), else: known
      alive_known = MapSet.new(alive ++ if(continuous, do: current, else: []), &elem(&1, 0))

      links = if continuous, do: [pgid], else: []
      {tracked, uncertain} = ProcScan.classify(infos, tracking, own, links, alive_known)

      tracked = Enum.flat_map(tracked, &identity(&1, starts))
      known = merge(known, tracked)
      survivors = Enum.uniq(Enum.filter(known, &alive?(&1, starts)) ++ tracked)
      signal_tracked(pgid, survivors, continuous, signal)
      {:ok, tracked_result(known, current, survivors, uncertain, continuous)}
    end
  end

  defp tracked_result(known, current, survivors, uncertain, continuous) do
    %{
      members: known,
      empty?: current == [] and survivors == [] and uncertain == [],
      settled?: survivors == [] and (current == [] or not continuous),
      continuous?: continuous,
      unknown?: current != [] and not continuous,
      uncertain: Enum.map(uncertain, &{&1.pid, &1.comm})
    }
  end

  defp alive?({pid, start}, starts), do: starts[pid] == start

  defp signal_tracked(_pgid, _survivors, _continuous, nil), do: :ok

  defp signal_tracked(pgid, survivors, continuous, signal) do
    if continuous, do: Exec.signal_group(pgid, signal)
    Enum.each(survivors, fn {pid, _} -> Exec.signal_process(pid, signal) end)
  end

  defp identity(%{pid: pid}, starts) do
    case Map.fetch(starts, pid) do
      {:ok, start} ->
        [{pid, start}]

      :error ->
        case Exec.proc_start(pid) do
          {:ok, start} -> [{pid, start}]
          _ -> []
        end
    end
  end

  def kill_group(pgid, known, signal), do: step(pgid, known, signal)

  defp signal_members(_pgid, _members, _continuous, nil), do: :ok
  defp signal_members(pgid, _members, true, signal), do: Exec.signal_group(pgid, signal)

  defp signal_members(_pgid, members, false, signal),
    do: Enum.each(members, fn {pid, _} -> Exec.signal_process(pid, signal) end)

  def recover(pgid, known, opts \\ []) do
    deadline = System.monotonic_time(:millisecond) + Keyword.get(opts, :cleanup_timeout_ms, 5_000)

    case Keyword.get(opts, :tracking) do
      nil -> recover_until(pgid, known, deadline)
      tracking -> recover_tracked(pgid, known, tracking, deadline)
    end
  end

  # Crash recovery by tag: the members are ended; uncertain processes only
  # get a warning, as a reused process group does.
  defp recover_tracked(pgid, known, tracking, deadline) do
    case step(pgid, known, 9, tracking) do
      {:ok, %{settled?: true, unknown?: unknown?, uncertain: uncertain}} ->
        warn_uncertain(uncertain)
        if unknown?, do: {:error, :unrecognized_group}, else: :ok

      {:ok, %{members: members}} ->
        if System.monotonic_time(:millisecond) >= deadline do
          {:error, :group_cleanup_timeout}
        else
          Process.sleep(100)
          recover_tracked(pgid, members, tracking, deadline)
        end

      {:error, _} = error ->
        error
    end
  end

  defp warn_uncertain([]), do: :ok

  defp warn_uncertain(uncertain) do
    Logger.warning(
      "Left running, cannot tell whether they descend from the run: " <> describe(uncertain)
    )
  end

  def describe(uncertain),
    do: Enum.map_join(uncertain, ", ", fn {pid, comm} -> "pid #{pid} (#{comm})" end)

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
      case Env.cmd(ps, ["-A", "-o", "pid=", "-o", "pgid=", "-o", "lstart="],
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
