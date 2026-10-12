defmodule HelmsmanDaemon.E2EControl do
  @moduledoc "Test-only file IPC; acknowledges a targeted worker kill after its DOWN."
  use GenServer
  alias HelmsmanDaemon.{AtomicFile, Paths}

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(opts) do
    directory = Paths.private_dir!(Keyword.fetch!(opts, :directory))
    send(self(), :poll)
    {:ok, %{directory: directory, pending: %{}}}
  end

  @impl true
  def handle_info(:poll, state) do
    state =
      state.directory
      |> Path.join("*.json")
      |> Path.wildcard()
      |> Enum.reject(&String.ends_with?(&1, ".reply.json"))
      |> Enum.reduce(state, &command/2)

    Process.send_after(self(), :poll, 10)
    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    {{path, id}, pending} = Map.pop!(state.pending, ref)
    reply(path, %{"status" => "killed", "run_id" => id})
    {:noreply, %{state | pending: pending}}
  end

  defp command(path, state) do
    with {:ok, contents} <- File.read(path),
         {:ok, %{"op" => "kill_run", "run_id" => id}} when is_integer(id) and id > 0 <-
           Jason.decode(contents) do
      File.rm!(path)

      case Registry.lookup(HelmsmanDaemon.RunRegistry, id) do
        [{pid, _}] ->
          ref = Process.monitor(pid)
          Process.exit(pid, :kill)
          %{state | pending: Map.put(state.pending, ref, {path, id})}

        [] ->
          reply(path, %{"status" => "not_found", "run_id" => id})
          state
      end
    else
      _ ->
        File.rm!(path)
        reply(path, %{"status" => "invalid_command"})
        state
    end
  end

  defp reply(path, payload) do
    reply_path = String.replace_suffix(path, ".json", ".reply.json")
    :ok = AtomicFile.write(reply_path, Jason.encode!(payload))
  end
end
