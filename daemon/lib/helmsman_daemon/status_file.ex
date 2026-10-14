defmodule HelmsmanDaemon.StatusFile do
  @moduledoc """
  `<home>/status.json`: what `helmsman daemon status` shows about a running
  daemon (0600, atomic replacement, never a token).

  Written when the connection changes, when runs are claimed or end, and every
  30 seconds; removed when the daemon stops normally. A file whose `updated_at`
  is more than 90 seconds old and whose PID is gone (or is not helmsman) is
  stale: the daemon is not running.
  """
  use GenServer
  require Logger
  alias HelmsmanDaemon.{AtomicFile, Credentials, Env, Paths, Release}

  @stale_after_s 90

  def path, do: Path.join(Paths.home(), "status.json")

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def identity(server_url, daemon_id), do: cast({:identity, server_url, daemon_id})
  def connected, do: cast(:connected)
  def disconnected, do: cast(:disconnected)
  def message_received, do: cast(:message)
  def changed, do: cast(:write)

  # Casts to a daemon that is not running (CLI commands, tests) are dropped.
  defp cast(message), do: GenServer.cast(__MODULE__, message)

  @doc "Decoded status.json."
  def read do
    with {:ok, data} <- File.read(path()),
         {:ok, map} when is_map(map) <- Jason.decode(data) do
      {:ok, map}
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid}
    end
  end

  @doc """
  False when `updated_at` is more than 90 seconds old and the recorded PID is
  not a running helmsman process. Options: `:now` (DateTime), `:pid_alive?`.
  """
  def live?(status, opts \\ []) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
    pid_alive? = Keyword.get(opts, :pid_alive?, &helmsman_pid?/1)

    fresh? =
      case DateTime.from_iso8601(status["updated_at"] || "") do
        {:ok, updated_at, _} -> DateTime.diff(now, updated_at) <= @stale_after_s
        _ -> false
      end

    fresh? or (is_integer(status["pid"]) and pid_alive?.(status["pid"]))
  end

  @doc "True when PID is a running process whose command line mentions helmsman."
  def helmsman_pid?(pid) when is_integer(pid) and pid > 0 do
    case System.find_executable("ps") do
      nil ->
        false

      ps ->
        case Env.cmd(ps, ["-p", Integer.to_string(pid), "-o", "command="], stderr_to_stdout: true) do
          {command, 0} -> command =~ "helmsman"
          _ -> false
        end
    end
  end

  def helmsman_pid?(_), do: false

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    now = now()

    state = %{
      interval: Keyword.get(opts, :status_interval_ms, 30_000),
      started_at: now,
      server_url: nil,
      daemon_id: nil,
      connected: false,
      connected_at: nil,
      last_message_at: nil,
      credentials_store: credentials_store()
    }

    write(state)
    schedule(state)
    {:ok, state}
  end

  @impl true
  def handle_cast({:identity, server_url, daemon_id}, state) do
    {:noreply, write(%{state | server_url: server_url, daemon_id: daemon_id})}
  end

  def handle_cast(:connected, state) do
    now = now()
    {:noreply, write(%{state | connected: true, connected_at: now, last_message_at: now})}
  end

  def handle_cast(:disconnected, %{connected: false} = state), do: {:noreply, state}

  def handle_cast(:disconnected, state),
    do: {:noreply, write(%{state | connected: false, connected_at: nil})}

  def handle_cast(:message, state), do: {:noreply, %{state | last_message_at: now()}}
  def handle_cast(:write, state), do: {:noreply, write(state)}

  @impl true
  def handle_info(:tick, state) do
    schedule(state)
    {:noreply, write(state)}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, _state) do
    File.rm(path())
    :ok
  end

  defp schedule(state), do: Process.send_after(self(), :tick, state.interval)

  defp write(state) do
    status = %{
      pid: String.to_integer(System.pid()),
      version: Release.version(),
      protocol: HelmsmanProtocol.version(),
      target: Release.target(),
      server_url: state.server_url,
      daemon_id: state.daemon_id,
      connected: state.connected,
      connected_at: iso(state.connected_at),
      last_message_at: iso(state.last_message_at),
      running_runs: running_runs(),
      credentials_store: state.credentials_store,
      started_at: iso(state.started_at),
      updated_at: iso(now())
    }

    case AtomicFile.write(path(), Jason.encode!(status)) do
      :ok -> :ok
      _ -> Logger.warning("Could not write #{path()}")
    end

    state
  rescue
    error ->
      Logger.warning("Could not write status.json: #{Exception.message(error)}")
      state
  end

  defp running_runs do
    HelmsmanDaemon.RunRegistry
    |> Registry.select([{{:"$1", :"$2", :_}, [], [{{:"$1", :"$2"}}]}])
    |> Enum.filter(fn {_id, pid} -> Process.alive?(pid) end)
    |> Enum.map(&elem(&1, 0))
    |> Enum.sort()
  rescue
    ArgumentError -> []
  end

  defp credentials_store do
    case Credentials.store() do
      {:ok, store} -> Atom.to_string(store)
      _ -> nil
    end
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
  defp iso(nil), do: nil
  defp iso(time), do: DateTime.to_iso8601(time)
end
