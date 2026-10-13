defmodule HelmsmanDaemon.Config do
  @moduledoc "Validated local TOML configuration."
  use GenServer
  alias HelmsmanDaemon.Adapters.Codex.Home
  alias HelmsmanDaemon.Adapters.Cursor.Home, as: CursorHome
  alias HelmsmanDaemon.{Env, Paths}

  def load do
    Paths.ensure!()

    case File.read(Path.join(Paths.home(), "config.toml")) do
      {:ok, contents} ->
        with {:ok, values} <- Toml.decode(contents), do: validate(values)

      {:error, :enoent} ->
        validate(%{})

      error ->
        error
    end
  end

  defp validate(values) do
    concurrency = Map.get(values, "max_concurrency", 4)
    level = Map.get(values, "log_level", "info")

    if is_integer(concurrency) and concurrency in 1..32 and level in ~w(debug info warning error) do
      with {:ok, codex_home} <- codex_home(values) do
        {:ok,
         %{
           codex_home: codex_home,
           cursor: CursorHome.configured(Map.get(values, "cursor")),
           server_url: Map.get(values, "server_url"),
           max_concurrency: concurrency,
           log_level: String.to_existing_atom(level)
         }}
      end
    else
      {:error, :invalid_config}
    end
  end

  defp codex_home(values) do
    case Map.get(values, "codex", %{}) do
      codex when is_map(codex) ->
        Home.configured(codex["home"], System.get_env())

      _ ->
        {:error, :invalid_codex_home}
    end
  end

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  def get, do: GenServer.call(__MODULE__, :get)

  @impl true
  def init(_opts) do
    with {:ok, _kill} <- HelmsmanDaemon.Exec.resolve_kill(),
         {:ok, _ps} <- HelmsmanDaemon.Exec.resolve_ps(),
         {:ok, config} <- load() do
      location = Home.location(config.codex_home, Env.child())

      {:ok, Map.put(config, :codex_location, location)}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call(:get, _from, config), do: {:reply, config, config}
end
