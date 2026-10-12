defmodule Helmsman.GitHub.Tokens do
  @moduledoc """
  Installation access tokens (designs/15 §1), cached in ETS until 5 minutes
  before they expire.

  Tokens may be narrowed to repositories and permissions; the cache key is
  `{installation_id, repository_ids, permissions}`, so every narrowing is
  cached on its own.

  Fresh tokens are read from ETS in the caller. On a miss the caller asks
  this process for the key: the first caller fetches the token itself (the
  GitHub request runs in the caller, never here) while later callers for
  the same key wait for its result, so concurrent misses issue one request.
  If the fetching caller dies, a waiter takes over. `purge/1` drops the
  cached tokens and keeps tokens being fetched for the installation from
  being cached.
  """

  use GenServer

  alias Helmsman.GitHub.Client

  @table __MODULE__
  @min_remaining_seconds 300

  @type token :: %{token: String.t(), expires_at: DateTime.t()}

  @doc false
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Returns a token of GitHub installation `installation_id`.

  ## Options

    * `:repository_ids` - GitHub repository IDs to narrow the token to
    * `:permissions` - a map such as `%{"contents" => "write"}`
    * `:now` - the current time (tests inject it)
  """
  @spec get(pos_integer(), keyword()) :: {:ok, token()} | {:error, Client.error()}
  def get(installation_id, opts \\ []) when is_integer(installation_id) do
    repository_ids = opts |> Keyword.get(:repository_ids) |> normalize_ids()
    key = {installation_id, repository_ids, Keyword.get(opts, :permissions)}
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)

    case cached(key, now) do
      {:ok, _token} = hit -> hit
      :miss -> acquire(key, now)
    end
  end

  defp acquire(key, now) do
    case GenServer.call(__MODULE__, {:acquire, key, now}, :infinity) do
      {:cached, token} ->
        {:ok, token}

      {:done, result} ->
        result

      :fetch ->
        result = fetch(key)
        GenServer.call(__MODULE__, {:fetched, key, result}, :infinity)
        result
    end
  end

  @doc "Drops every cached token of `installation_id`."
  @spec purge(pos_integer()) :: :ok
  def purge(installation_id), do: GenServer.call(__MODULE__, {:purge, installation_id})

  ## Server

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    # key => %{owner: pid, monitor: ref, waiters: [from], purged?: boolean}
    {:ok, %{}}
  end

  @impl true
  def handle_call({:acquire, key, now}, {pid, _tag} = from, flights) do
    case {cached(key, now), flights} do
      {{:ok, token}, _flights} ->
        {:reply, {:cached, token}, flights}

      {:miss, %{^key => flight}} ->
        {:noreply, Map.put(flights, key, %{flight | waiters: [from | flight.waiters]})}

      {:miss, _flights} ->
        flight = %{owner: pid, monitor: Process.monitor(pid), waiters: [], purged?: false}
        {:reply, :fetch, Map.put(flights, key, flight)}
    end
  end

  def handle_call({:fetched, key, result}, _from, flights) do
    case Map.pop(flights, key) do
      {nil, flights} ->
        {:reply, :ok, flights}

      {flight, flights} ->
        Process.demonitor(flight.monitor, [:flush])
        unless flight.purged?, do: store(key, result)
        Enum.each(flight.waiters, &GenServer.reply(&1, {:done, result}))
        {:reply, :ok, flights}
    end
  end

  def handle_call({:purge, installation_id}, _from, flights) do
    :ets.match_delete(@table, {{installation_id, :_, :_}, :_})

    flights =
      Map.new(flights, fn
        {{^installation_id, _, _} = key, flight} -> {key, %{flight | purged?: true}}
        other -> other
      end)

    {:reply, :ok, flights}
  end

  # The fetching caller died: the oldest waiter fetches instead.
  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, flights) do
    case Enum.find(flights, fn {_key, flight} -> flight.monitor == ref end) do
      nil -> {:noreply, flights}
      {key, flight} -> {:noreply, hand_over(flights, key, flight)}
    end
  end

  defp hand_over(flights, key, %{waiters: []}), do: Map.delete(flights, key)

  defp hand_over(flights, key, flight) do
    [{pid, _tag} = next | rest] = Enum.reverse(flight.waiters)
    GenServer.reply(next, :fetch)

    Map.put(flights, key, %{
      flight
      | owner: pid,
        monitor: Process.monitor(pid),
        waiters: Enum.reverse(rest)
    })
  end

  ## Cache and GitHub

  defp cached(key, now) do
    case :ets.lookup(@table, key) do
      [{^key, token}] -> if fresh?(token, now), do: {:ok, token}, else: :miss
      [] -> :miss
    end
  end

  defp store(key, {:ok, token}), do: :ets.insert(@table, {key, token})
  defp store(_key, _error), do: true

  defp normalize_ids(nil), do: nil
  defp normalize_ids(ids), do: ids |> Enum.uniq() |> Enum.sort()

  defp fresh?(%{expires_at: expires_at}, now),
    do: DateTime.diff(expires_at, now) > @min_remaining_seconds

  defp fetch({installation_id, repository_ids, permissions}) do
    body =
      %{}
      |> put_unless_nil("repository_ids", repository_ids)
      |> put_unless_nil("permissions", permissions)

    case Client.request(:post, "/app/installations/#{installation_id}/access_tokens",
           auth: :app,
           json: body
         ) do
      {:ok, %{"token" => token, "expires_at" => expires_at}} when is_binary(token) ->
        parse(token, expires_at)

      {:ok, _body} ->
        {:error, {:github_unavailable, :unexpected_response}}

      {:error, _reason} = error ->
        error
    end
  end

  defp parse(token, expires_at) do
    case DateTime.from_iso8601(to_string(expires_at)) do
      {:ok, expires_at, _offset} -> {:ok, %{token: token, expires_at: expires_at}}
      {:error, _reason} -> {:error, {:github_unavailable, :unexpected_response}}
    end
  end

  defp put_unless_nil(map, _key, nil), do: map
  defp put_unless_nil(map, key, value), do: Map.put(map, key, value)
end
