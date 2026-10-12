defmodule HelmsmanMCP.Sessions do
  @moduledoc """
  The MCP sessions of this node (designs/08 §1): session ID → the
  credential that opened it (`Helmsman.Accounts.Scope.credential/1`: an
  API token or a run), its user and workspace, the session process and the
  session identity.

  A named `:protected` ETS table: `lookup/1` reads it directly, every write
  goes through this GenServer, one at a time. An entry is removed only by
  the process that registered it (`delete/2`), when that process exits
  (monitor) or when it has not been seen for 24 hours and 5 minutes.
  """

  use GenServer

  alias Helmsman.Accounts.Scope

  @table __MODULE__
  @touch_after_ms :timer.seconds(60)
  @sweep_every_ms :timer.minutes(10)
  @max_idle_ms :timer.hours(24) + :timer.minutes(5)

  @type source :: :identify | :auto | nil
  @type entry :: %{
          credential: {:api_token, pos_integer()} | {:run, pos_integer()},
          user_id: pos_integer(),
          workspace_id: pos_integer(),
          pid: pid(),
          monitor_ref: reference(),
          actor_id: pos_integer() | nil,
          source: source(),
          last_seen_at: integer()
        }

  @doc false
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Registers `session_id` for the credential of `scope`, served by `pid`, with no
  session identity. A previous entry of the ID is replaced.
  """
  @spec register(String.t(), Scope.t(), pid()) :: :ok
  def register(session_id, %Scope{} = scope, pid) when is_binary(session_id) and is_pid(pid),
    do: GenServer.call(__MODULE__, {:register, session_id, scope, pid})

  @doc "Returns the entry of `session_id`, or nil."
  @spec lookup(String.t() | nil) :: entry() | nil
  def lookup(session_id) when is_binary(session_id) do
    case :ets.lookup(@table, session_id) do
      [{^session_id, entry}] -> entry
      [] -> nil
    end
  end

  def lookup(nil), do: nil

  @doc "Sets the session identity; `:error` if the session is not registered."
  @spec put_identity(String.t(), pos_integer(), :identify | :auto) :: :ok | :error
  def put_identity(session_id, actor_id, source)
      when is_binary(session_id) and is_integer(actor_id) and source in [:identify, :auto],
      do: GenServer.call(__MODULE__, {:put_identity, session_id, actor_id, source})

  @doc """
  Records that the session was used, at most once a minute (asynchronous).
  """
  @spec touch(String.t()) :: :ok
  def touch(session_id) when is_binary(session_id) do
    case lookup(session_id) do
      %{last_seen_at: seen} ->
        if now() - seen >= @touch_after_ms,
          do: GenServer.cast(__MODULE__, {:touch, session_id}),
          else: :ok

      nil ->
        :ok
    end
  end

  @doc """
  Removes the entry of `session_id` if `pid` registered it; otherwise does
  nothing.
  """
  @spec delete(String.t(), pid()) :: :ok
  def delete(session_id, pid) when is_binary(session_id) and is_pid(pid),
    do: GenServer.call(__MODULE__, {:delete, session_id, pid})

  defp now, do: System.monotonic_time(:millisecond)

  ## Server

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :protected, :set, read_concurrency: true])
    schedule_sweep()
    {:ok, %{refs: %{}}}
  end

  @impl true
  def handle_call({:register, session_id, scope, pid}, _from, state) do
    state = drop(state, session_id)
    ref = Process.monitor(pid)

    entry = %{
      credential: Scope.credential(scope),
      user_id: scope.user.id,
      workspace_id: scope.workspace.id,
      pid: pid,
      monitor_ref: ref,
      actor_id: nil,
      source: nil,
      last_seen_at: now()
    }

    :ets.insert(@table, {session_id, entry})
    {:reply, :ok, put_in(state.refs[ref], session_id)}
  end

  def handle_call({:put_identity, session_id, actor_id, source}, _from, state) do
    case lookup(session_id) do
      nil ->
        {:reply, :error, state}

      entry ->
        :ets.insert(@table, {session_id, %{entry | actor_id: actor_id, source: source}})
        {:reply, :ok, state}
    end
  end

  def handle_call({:delete, session_id, pid}, _from, state) do
    case lookup(session_id) do
      %{pid: ^pid} -> {:reply, :ok, drop(state, session_id)}
      _other -> {:reply, :ok, state}
    end
  end

  @impl true
  def handle_cast({:touch, session_id}, state) do
    with %{} = entry <- lookup(session_id) do
      :ets.insert(@table, {session_id, %{entry | last_seen_at: now()}})
    end

    {:noreply, state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    {session_id, refs} = Map.pop(state.refs, ref)
    state = %{state | refs: refs}

    case lookup(session_id) do
      %{monitor_ref: ^ref} ->
        :ets.delete(@table, session_id)
        {:noreply, state}

      _other ->
        {:noreply, state}
    end
  end

  def handle_info(:sweep, state) do
    schedule_sweep()
    {:noreply, sweep(state, now())}
  end

  # Tests pass the current time to check the expiry.
  def handle_info({:sweep, now}, state) when is_integer(now), do: {:noreply, sweep(state, now)}

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_every_ms)

  # The only removal that does not check who registered the entry.
  defp sweep(state, now) do
    :ets.tab2list(@table)
    |> Enum.filter(fn {_id, entry} -> now - entry.last_seen_at > @max_idle_ms end)
    |> Enum.reduce(state, fn {session_id, _entry}, state -> drop(state, session_id) end)
  end

  defp drop(state, session_id) do
    case lookup(session_id) do
      %{monitor_ref: ref} ->
        Process.demonitor(ref, [:flush])
        :ets.delete(@table, session_id)
        %{state | refs: Map.delete(state.refs, ref)}

      nil ->
        state
    end
  end
end
