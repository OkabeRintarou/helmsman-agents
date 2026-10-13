defmodule HelmsmanDaemon.ProcScan do
  @moduledoc """
  Linux `/proc` scan for the descendants of a CLI that left its process group
  (`add-cursor-adapter` decision 10).

  Every launch of an adapter that declares `Launch.track_descendants` gets a
  tag of its own in the CLI's environment. A process's start-up environment
  survives fork, exec, `setsid` and being adopted by init, so every
  descendant carries the tag. For each process of the daemon's user the scan
  reads the environment: tagged, untagged, or unknown when it cannot be read
  for another reason than the process having exited (`EACCES` for a process
  that made itself non-dumpable). An unknown process is a member when it is
  linked to a known member by parent, process group or session; it is
  ignored when it started before the CLI; otherwise it is uncertain: never
  signalled, but it keeps the cleanup barrier from clearing.
  """

  @var "HELMSMAN_PROC_TAG"
  @exited [:enoent, :esrch]

  @type tracking :: %{
          required(:tag) => String.t(),
          required(:since) => non_neg_integer(),
          optional(:reader) => (Path.t() -> {:ok, binary()} | {:error, atom()})
        }
  @type info :: %{
          pid: pos_integer(),
          ppid: non_neg_integer(),
          pgrp: non_neg_integer(),
          sid: non_neg_integer(),
          start: non_neg_integer(),
          comm: String.t(),
          env: :tagged | :untagged | :unknown
        }

  def var, do: @var

  def new_tag(run_id),
    do: "#{run_id}." <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)

  @doc "Whether this system can track descendants (Linux with `/proc`)."
  def supported?(os \\ Application.get_env(:helmsman_daemon, :os_type, :os.type())),
    do: os == {:unix, :linux} and File.exists?("/proc/self/environ")

  def unsupported_reason, do: "descendant tracking needs Linux /proc"

  @doc "Clock ticks since boot now, a lower bound for the start of a process launched next."
  def now_ticks do
    with {:ok, uptime} <- File.read("/proc/uptime"),
         [seconds | _] <- String.split(uptime),
         {value, _} <- Float.parse(seconds) do
      max(trunc(value * clock_ticks()) - 1, 0)
    else
      _ -> 0
    end
  end

  defp clock_ticks do
    case :persistent_term.get({__MODULE__, :clk_tck}, nil) do
      nil ->
        ticks =
          case HelmsmanDaemon.Env.cmd("getconf", ["CLK_TCK"], stderr_to_stdout: true) do
            {value, 0} -> value |> String.trim() |> String.to_integer()
            _ -> 100
          end

        :persistent_term.put({__MODULE__, :clk_tck}, ticks)
        ticks
    end
  rescue
    _ -> 100
  end

  @doc "Same-user live processes other than the daemon, with their tag state."
  @spec scan(tracking()) :: {:ok, [info()], map()} | {:error, atom()}
  def scan(tracking) do
    reader = Map.get(tracking, :reader, &File.read/1)

    with {:ok, names} <- File.ls("/proc"),
         {:ok, own} <- self_info(reader) do
      infos = Enum.flat_map(names, &read_entry(&1, own, tracking.tag, reader))
      {:ok, infos, own}
    else
      _ -> {:error, :process_scan_failed}
    end
  end

  defp read_entry(name, own, tag, reader) do
    case Integer.parse(name) do
      {pid, ""} when pid != own.pid -> read(pid, own.uid, tag, reader)
      _ -> []
    end
  end

  defp self_info(reader) do
    with {:ok, status} <- reader.("/proc/self/status"),
         {:ok, uid} <- uid(status),
         {:ok, stat} <- reader.("/proc/self/stat"),
         {:ok, fields} <- stat(stat) do
      {:ok, Map.put(fields, :uid, uid)}
    else
      _ -> {:error, :self}
    end
  end

  defp read(pid, uid, tag, reader) do
    base = "/proc/#{pid}"

    with {:ok, status} <- reader.(base <> "/status"),
         {:ok, ^uid} <- uid(status),
         {:ok, stat} <- reader.(base <> "/stat"),
         {:ok, %{state: state} = fields} when state not in ["Z", "X"] <- stat(stat),
         {:ok, env} <- environment(reader.(base <> "/environ"), tag) do
      [fields |> Map.delete(:state) |> Map.put(:env, env)]
    else
      _ -> []
    end
  end

  defp environment({:ok, data}, tag) do
    if (@var <> "=" <> tag) in :binary.split(data, <<0>>, [:global]),
      do: {:ok, :tagged},
      else: {:ok, :untagged}
  end

  defp environment({:error, reason}, _tag) when reason in @exited, do: :exited
  defp environment({:error, _reason}, _tag), do: {:ok, :unknown}

  defp uid(status) do
    case Regex.run(~r/^Uid:\s+(\d+)/m, status) do
      [_, uid] -> {:ok, String.to_integer(uid)}
      _ -> :error
    end
  end

  @doc false
  def stat(data) do
    with [{open, _} | _] <- :binary.matches(data, "("),
         [_ | _] = closes <- :binary.matches(data, ")"),
         {close, _} = List.last(closes),
         {pid, _} <- Integer.parse(binary_part(data, 0, open)),
         rest = binary_part(data, close + 2, byte_size(data) - close - 2),
         [state, ppid, pgrp, sid | more] <- String.split(rest, " "),
         start when is_binary(start) <- Enum.at(more, 15) do
      {:ok,
       %{
         pid: pid,
         state: state,
         ppid: String.to_integer(ppid),
         pgrp: String.to_integer(pgrp),
         sid: String.to_integer(sid),
         start: String.to_integer(start),
         comm: binary_part(data, open + 1, close - open - 1)
       }}
    else
      _ -> :error
    end
  rescue
    _ -> :error
  end

  @doc """
  Splits scanned processes into members and uncertain processes.

  `alive_known`: PIDs of known members whose identity (PID + start time)
  is confirmed now; `links`: further process groups proven to be the run's
  (the CLI's group while its continuity holds). Only verified, live members
  link: a PID of a member that exited, or whose start time no longer
  matches, may belong to an unrelated process now (code review 1 P1). The
  daemon's own process group and session never link: the CLI may share the
  daemon's session.
  """
  def classify(infos, tracking, own, links, alive_known) do
    members =
      Enum.filter(infos, &(&1.env == :tagged or MapSet.member?(alive_known, &1.pid)))

    unknown =
      Enum.filter(
        infos,
        &(&1.env == :unknown and not MapSet.member?(alive_known, &1.pid) and
            &1.start >= tracking.since)
      )

    link(members, unknown, MapSet.new(links), MapSet.new([own.pgrp, own.sid]))
  end

  defp link(members, unknown, links, own_groups) do
    parents = MapSet.new(members, & &1.pid)

    groups =
      members
      |> Enum.flat_map(&[&1.pid, &1.pgrp, &1.sid])
      |> MapSet.new()
      |> MapSet.union(links)
      |> MapSet.difference(own_groups)

    {linked, rest} =
      Enum.split_with(unknown, fn info ->
        MapSet.member?(parents, info.ppid) or MapSet.member?(groups, info.pgrp) or
          MapSet.member?(groups, info.sid)
      end)

    if linked == [],
      do: {members, rest},
      else: link(members ++ linked, rest, links, own_groups)
  end
end
