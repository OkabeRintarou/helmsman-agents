defmodule Helmsman.McpServers.Check do
  @moduledoc "Ephemeral owner-only local checks; results go only to the requesting process."
  use GenServer
  import Ecto.Query
  alias Helmsman.{Agents, Events, Policy, Repo}

  alias Helmsman.Actors.Actor
  alias Helmsman.Daemons.{Daemon, Runtime}
  alias Helmsman.McpServers.Entry
  alias HelmsmanProtocol.{McpCheckServer, Push}

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def request(scope, name, recipient \\ self()) do
    with :ok <- Policy.authorize(scope, :manage_mcp_servers),
         %Actor{} = actor <-
           Repo.get_by(Actor,
             workspace_id: scope.workspace.id,
             name: name,
             owner_id: scope.user.id,
             kind: :agent
           ),
         {:ok, profile} <- Agents.execution_config(actor.id),
         {:ok, runtime, daemon} <- runtime(profile, scope.user.id) do
      mcp = profile.extra_mcp_servers || %{}

      servers =
        Enum.map(mcp, fn {server_name, entry} ->
          %McpCheckServer{
            name: server_name,
            type: check_type(entry),
            command: if(is_map(entry), do: entry["command"], else: nil),
            env_refs: Entry.references(entry)
          }
        end)

      if length(servers) <= 64 and
           Enum.all?(servers, &match?({:ok, _}, McpCheckServer.new(Map.from_struct(&1)))) do
        GenServer.call(
          __MODULE__,
          {:request, actor.id, daemon.id, runtime.id, profile.env || %{}, servers, recipient}
        )
      else
        {:error, :invalid_configuration}
      end
    else
      nil -> {:error, :not_found}
      error -> error
    end
  end

  defp check_type(entry) do
    case Entry.type(entry) do
      "stdio" -> :stdio
      "sse" -> :sse
      _ -> :http
    end
  end

  def deliver(daemon_id, report), do: GenServer.call(__MODULE__, {:deliver, daemon_id, report})

  defp runtime(%{runtime_id: nil}, _), do: {:error, :no_runtime}

  defp runtime(profile, user_id) do
    case Repo.one(
           from r in Runtime,
             join: d in Daemon,
             on: d.id == r.daemon_id,
             where:
               r.id == ^profile.runtime_id and d.user_id == ^user_id and is_nil(d.revoked_at),
             select: {r, d}
         ) do
      nil ->
        {:error, :daemon_offline}

      {runtime, daemon} ->
        available_runtime(runtime, daemon)
    end
  end

  defp available_runtime(%{status: status}, _) when status != "online",
    do: {:error, :daemon_offline}

  defp available_runtime(%{disabled_at: disabled}, _) when not is_nil(disabled),
    do: {:error, :runtime_disabled}

  defp available_runtime(runtime, daemon) do
    if (daemon.protocol_version || 0) < HelmsmanProtocol.mcp_env_version(),
      do: {:error, :daemon_outdated},
      else: {:ok, runtime, daemon}
  end

  @impl true
  def init(_), do: {:ok, %{pending: %{}, last: %{}}}
  @impl true
  def handle_call({:request, actor_id, daemon_id, runtime_id, env, servers, recipient}, _, state) do
    now = System.monotonic_time(:millisecond)

    if now - Map.get(state.last, actor_id, now - 10_000) < 10_000 do
      {:reply, {:error, :rate_limited}, state}
    else
      id = Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)

      push = %Push.McpCheck{
        check_id: id,
        runtime_id: runtime_id,
        agent_env: env,
        servers: servers
      }

      timer = Process.send_after(self(), {:timeout, id}, 10_000)
      monitor = Process.monitor(recipient)
      Events.broadcast(Events.topic(:daemon, daemon_id), {:mcp_check_request, push})
      entry = %{recipient: recipient, daemon_id: daemon_id, timer: timer, monitor: monitor}

      {:reply, {:ok, id},
       %{
         state
         | pending: Map.put(state.pending, id, entry),
           last:
             state.last
             |> Map.reject(fn {_, time} -> now - time >= 10_000 end)
             |> Map.put(actor_id, now)
       }}
    end
  end

  def handle_call({:deliver, daemon_id, report}, _, state) do
    case state.pending[report.check_id] do
      %{daemon_id: ^daemon_id} = entry ->
        send(entry.recipient, {:mcp_check_result, report.check_id, {:ok, report.results}})
        {:reply, :ok, remove(state, report.check_id)}

      _ ->
        {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_info({:timeout, id}, state) do
    if entry = state.pending[id],
      do: send(entry.recipient, {:mcp_check_result, id, {:error, :timeout}})

    {:noreply, remove(state, id)}
  end

  def handle_info({:DOWN, ref, :process, _, _}, state) do
    ids = for {id, %{monitor: ^ref}} <- state.pending, do: id
    {:noreply, Enum.reduce(ids, state, &remove(&2, &1))}
  end

  defp remove(state, id) do
    if entry = state.pending[id] do
      Process.cancel_timer(entry.timer)
      Process.demonitor(entry.monitor, [:flush])
    end

    %{state | pending: Map.delete(state.pending, id)}
  end
end
