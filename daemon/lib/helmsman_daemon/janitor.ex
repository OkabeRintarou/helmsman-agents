defmodule HelmsmanDaemon.Janitor do
  @moduledoc "Daily deletion of raw logs older than seven days."
  use GenServer
  alias HelmsmanDaemon.Paths
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def clean(now \\ System.os_time(:second)) do
    Path.wildcard(Path.join([Paths.home(), "runs", "*", "raw.log"]))
    |> Enum.each(fn path ->
      case File.stat(path, time: :posix) do
        {:ok, stat} when stat.mtime < now - 7 * 86_400 ->
          File.rm(path)
          File.rmdir(Path.dirname(path))

        _ ->
          :ok
      end
    end)

    :ok
  end

  @impl true
  def init(_opts) do
    send(self(), :clean)
    {:ok, nil}
  end

  @impl true
  def handle_info(:clean, state) do
    clean()
    Process.send_after(self(), :clean, 86_400_000)
    {:noreply, state}
  end
end
