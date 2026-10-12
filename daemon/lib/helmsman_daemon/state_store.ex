defmodule HelmsmanDaemon.StateStore do
  @moduledoc "Durable OS process identity records and conservative crash recovery."
  use GenServer
  require Logger
  alias HelmsmanDaemon.{AtomicFile, Paths, ProcGroup, Workspace}

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def write(id, fields) do
    Paths.private_dir!(Paths.state())
    AtomicFile.write(Paths.record(id), Jason.encode!(Map.put(fields, :run_id, id)))
  end

  def read(id) do
    with {:ok, data} <- File.read(Paths.record(id)), do: Jason.decode(data)
  end

  def delete(id), do: File.rm(Paths.record(id))

  def recover(active_ids \\ []) do
    Paths.private_dir!(Paths.state())

    Paths.state()
    |> Path.join("*.json")
    |> Path.wildcard()
    |> Enum.each(fn path ->
      with {id, ""} <- Integer.parse(Path.basename(path, ".json")),
           true <- id > 0 and id not in active_ids do
        recover_run(id)
      end
    end)

    :ok
  end

  def recover_run(id) do
    result =
      case read(id) do
        {:ok, record} ->
          kill_record(record)

        _ ->
          Logger.warning("Unreadable state record for run #{id}")
          {:error, :unreadable_record}
      end

    Workspace.cleanup(id)

    if result == :ok,
      do: delete(id),
      else: Logger.warning("Unresolved process group retained for run #{id}")

    result
  end

  def kill_record(%{"pgid" => pgid} = record) when is_integer(pgid) and pgid > 0 do
    result = ProcGroup.recover(pgid, ProcGroup.from_record(record))
    if result != :ok, do: Logger.warning("Process group identity or cleanup unresolved")
    result
  end

  def kill_record(_record), do: :ok

  @impl true
  def init(_opts) do
    recover()
    {:ok, nil}
  end
end
