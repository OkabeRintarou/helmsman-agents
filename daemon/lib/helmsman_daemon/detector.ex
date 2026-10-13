defmodule HelmsmanDaemon.Detector do
  @moduledoc "Periodic adapter detection and protocol CLI inventory."
  use GenServer
  require Logger
  alias HelmsmanDaemon.{Adapter, Env, ProcScan}
  alias HelmsmanDaemon.Adapters.Codex.Config, as: CodexConfig
  alias HelmsmanProtocol.CLI

  def scan(adapters \\ Adapter.registered()), do: Enum.map(adapters, &detect/1)
  def available?(clis), do: Enum.any?(clis, & &1.available)
  def inventory, do: GenServer.call(__MODULE__, :inventory)
  def refresh, do: GenServer.cast(__MODULE__, :refresh)
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  defp detect(adapter) do
    if tracks_descendants?(adapter) and not ProcScan.supported?() do
      cli(adapter, nil, [], false, ProcScan.unsupported_reason())
    else
      case adapter.detect() do
        {:ok, info} -> detected(adapter, info)
        {:error, reason} -> cli(adapter, nil, [], false, reason)
      end
    end
  end

  # add-cursor-adapter decision 10: fail closed where descendants cannot be followed.
  defp tracks_descendants?(adapter) do
    Code.ensure_loaded(adapter)
    function_exported?(adapter, :track_descendants?, 0) and adapter.track_descendants?()
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
          else: %{
            cli(adapter, info.version, info.models, true, nil)
            | efforts: Map.get(info, :efforts, [])
          }

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
      clis: [],
      codex_hint_once: Keyword.get_lazy(opts, :codex_hint_once, fn -> :atomics.new(1, []) end),
      codex_checked?: false
    }

    state = %{state | clis: scan(state.adapters)} |> codex_hint()

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

    %{state | clis: clis} |> codex_hint()
  end

  defp codex_hint(%{codex_checked?: true} = state), do: state

  defp codex_hint(state) do
    if Enum.any?(state.clis, &(&1.provider == :codex and &1.available)) do
      if :atomics.compare_exchange(state.codex_hint_once, 1, 0, 1) == :ok,
        do: check_codex_hint()

      %{state | codex_checked?: true}
    else
      state
    end
  end

  defp check_codex_hint do
    alias HelmsmanDaemon.Adapters.Codex.{Home, Source}

    with {:ok, {_mode, home} = location} <- Home.resolve() do
      if hint = Home.migration_hint(location), do: Logger.warning(hint)

      case CodexConfig.provider_source(nil, home, Env.child()) do
        {:error, reason} ->
          Logger.warning(
            "Codex is installed but not configured for the Helmsman daemon; Codex agents without a provider account will fail. " <>
              Source.error(reason, home)
          )

        _ ->
          :ok
      end
    end
  end
end
