defmodule HelmsmanDaemon.Detector do
  @moduledoc "Periodic adapter detection and protocol CLI inventory."
  use GenServer
  alias HelmsmanDaemon.Adapter
  alias HelmsmanProtocol.CLI

  def scan(adapters \\ Adapter.registered()), do: Enum.map(adapters, &detect/1)
  def available?(clis), do: Enum.any?(clis, & &1.available)
  def inventory, do: GenServer.call(__MODULE__, :inventory)
  def refresh, do: GenServer.cast(__MODULE__, :refresh)
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  defp detect(adapter) do
    case adapter.detect() do
      {:ok, info} -> detected(adapter, info)
      {:error, reason} -> cli(adapter, nil, [], false, reason)
    end
  end

  defp detected(adapter, info) do
    case Version.parse(info.version) do
      {:ok, version} ->
        if Version.compare(version, adapter.min_version()) == :lt,
          do:
            cli(
              adapter,
              info.version,
              info.models,
              false,
              "CLI version too old; requires #{adapter.min_version()}"
            ),
          else: cli(adapter, info.version, info.models, true, nil)

      :error ->
        cli(adapter, info.version, info.models, false, "Invalid CLI version")
    end
  end

  defp cli(adapter, version, models, available, reason) do
    %CLI{
      provider: adapter.provider(),
      version: version,
      models: models,
      efforts: [],
      available: available,
      unavailable_reason: reason
    }
  end

  @impl true
  def init(opts) do
    state = %{
      adapters: Keyword.get(opts, :adapters, Adapter.registered()),
      interval: Keyword.get(opts, :detect_interval_ms, 600_000),
      clis: []
    }

    state = %{state | clis: scan(state.adapters)}

    if available?(state.clis) do
      Process.send_after(self(), :refresh, state.interval)
      {:ok, state}
    else
      {:stop, :no_cli}
    end
  end

  @impl true
  def handle_call(:inventory, _from, state), do: {:reply, state.clis, state}
  @impl true
  def handle_cast(:refresh, state), do: {:noreply, rescan(state)}
  @impl true
  def handle_info(:refresh, state) do
    Process.send_after(self(), :refresh, state.interval)
    {:noreply, rescan(state)}
  end

  defp rescan(state) do
    clis = scan(state.adapters)

    if clis != state.clis and Process.whereis(HelmsmanDaemon.Connection),
      do: GenServer.cast(HelmsmanDaemon.Connection, :sync)

    %{state | clis: clis}
  end
end
