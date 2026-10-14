defmodule HelmsmanDaemon.Config do
  @moduledoc "Validated local TOML configuration."
  use GenServer
  alias HelmsmanDaemon.Adapters.Codex.Home
  alias HelmsmanDaemon.Adapters.Cursor.Home, as: CursorHome
  alias HelmsmanDaemon.{Env, Paths, Platform}

  def load(opts \\ []) do
    with {:ok, values} <- read(), do: validate(values, opts)
  end

  defp read do
    Paths.ensure!()

    case File.read(Path.join(Paths.home(), "config.toml")) do
      {:ok, contents} -> Toml.decode(contents)
      {:error, :enoent} -> {:ok, %{}}
      error -> error
    end
  end

  @doc """
  `[credentials] store`: `"keychain"` (macOS only, the macOS default) or `"file"`
  (the default elsewhere). `opts[:platform]` overrides the detected platform.
  """
  def credentials_store(opts \\ []) do
    case read() do
      {:ok, values} -> store(values, Keyword.get_lazy(opts, :platform, &Platform.os/0))
      _ -> {:error, :invalid_config}
    end
  end

  defp store(values, platform) do
    case Map.get(values, "credentials", %{}) do
      %{"store" => "file"} -> {:ok, :file}
      %{"store" => "keychain"} when platform == :macos -> {:ok, :keychain}
      %{"store" => _} -> {:error, :invalid_config}
      section when is_map(section) and platform == :macos -> {:ok, :keychain}
      section when is_map(section) -> {:ok, :file}
      _ -> {:error, :invalid_config}
    end
  end

  defp validate(values, opts) do
    concurrency = Map.get(values, "max_concurrency", 4)
    level = Map.get(values, "log_level", "info")

    if is_integer(concurrency) and concurrency in 1..32 and level in ~w(debug info warning error) do
      with {:ok, codex_home} <- codex_home(values),
           {:ok, store} <- store(values, Keyword.get_lazy(opts, :platform, &Platform.os/0)) do
        {:ok,
         %{
           codex_home: codex_home,
           cursor: CursorHome.configured(Map.get(values, "cursor")),
           server_url: Map.get(values, "server_url"),
           max_concurrency: concurrency,
           log_level: String.to_existing_atom(level),
           credentials_store: store
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
