defmodule HelmsmanDaemon.Adapters.Cursor.Home do
  @moduledoc """
  Cursor's private directories, configuration and environment
  (`add-cursor-adapter` decisions 1, 3–6).

  `<daemon home>/cursor/` (0700) holds `config/` (`CURSOR_CONFIG_DIR`, chats)
  and `data/` (`CURSOR_DATA_DIR`, never any MCP approval), both persistent.
  Every run gets a `HOME` of its own, `<run dir>/home`, whose user-level
  `.cursor/mcp.json` has only the run's MCP servers.
  """
  alias HelmsmanDaemon.{Config, Paths}

  @default_links [".gitconfig"]
  @kept ~w(CURSOR_API_KEY CURSOR_API_ENDPOINT)
  @disabled "Cursor runs are off: team policy from the Cursor dashboard and the repository's .cursor/hooks.json cannot be turned off for unattended runs. Set [cursor] enabled = true in the daemon config to allow them."

  @type config :: %{enabled: boolean(), home_links: [String.t()], error: String.t() | nil}

  def disabled_reason, do: @disabled

  @doc "Validates the `[cursor]` section of the daemon config; errors make Cursor unavailable."
  @spec configured(term()) :: config()
  def configured(nil), do: %{enabled: false, home_links: @default_links, error: nil}

  def configured(section) when is_map(section) do
    enabled = Map.get(section, "enabled", false)
    links = Map.get(section, "home_links", @default_links)
    links? = is_list(links) and Enum.all?(links, &is_binary/1)

    error =
      cond do
        not is_boolean(enabled) -> "[cursor] enabled must be true or false"
        not links? -> "[cursor] home_links must be a list of paths"
        true -> Enum.find_value(links, &link_error/1)
      end

    %{enabled: enabled == true, home_links: if(links?, do: links, else: []), error: error}
  end

  def configured(_), do: %{enabled: false, home_links: [], error: "[cursor] must be a table"}

  @doc "Entries are relative to `HOME`; Cursor's and Claude's own directories are never linked."
  def link_error(entry) do
    parts = entry |> String.split("/") |> Enum.reject(&(&1 in ["", "."]))

    cond do
      parts == [] -> "[cursor] home_links has an empty entry"
      Path.type(entry) != :relative or String.starts_with?(entry, "~") -> not_allowed(entry)
      ".." in parts -> not_allowed(entry)
      hd(parts) in [".cursor", ".claude"] -> not_allowed(entry)
      parts == [".config"] or Enum.take(parts, 2) == [".config", "cursor"] -> not_allowed(entry)
      true -> nil
    end
  end

  defp not_allowed(entry),
    do:
      "[cursor] home_links entry #{inspect(entry)} is not allowed " <>
        "(relative paths only; never .cursor, .claude, .config or .config/cursor)"

  @doc "The current `[cursor]` configuration: the running daemon's, or read from disk."
  def config do
    case Process.whereis(Config) do
      nil ->
        case Config.load() do
          {:ok, config} -> config.cursor
          _ -> %{enabled: false, home_links: [], error: "invalid daemon config.toml"}
        end

      _pid ->
        Config.get().cursor
    end
  end

  @doc "Fails closed when Cursor is not enabled or its configuration is invalid."
  def usable(%{error: error}) when is_binary(error), do: {:error, error}
  def usable(%{enabled: true}), do: :ok
  def usable(_config), do: {:error, @disabled}

  def config_dir, do: Path.join(Paths.cursor_root(), "config")
  def data_dir, do: Path.join(Paths.cursor_root(), "data")

  def ensure_dirs! do
    Enum.each([Paths.cursor_root(), config_dir(), data_dir()], &Paths.private_dir!/1)
    :ok
  end

  @doc "The daemon never approves an MCP server; anything else may have (decision 3)."
  def check_approvals(data \\ data_dir()) do
    approved =
      data
      |> Path.join("projects/*/mcp-approvals.json")
      |> Path.wildcard(match_dot: true)
      |> Enum.reject(&empty_approvals?/1)

    if approved == [],
      do: :ok,
      else:
        {:error,
         "Cursor's private data directory has MCP approvals Helmsman never writes; " <>
           "remove them and retry: " <>
           Enum.map_join(approved, ", ", &Path.relative_to(&1, data))}
  end

  defp empty_approvals?(path) do
    case File.read(path) do
      {:ok, contents} -> String.trim(contents) == "" or match?({:ok, []}, JSON.decode(contents))
      {:error, :enoent} -> true
      _ -> false
    end
  end

  @doc "Whether Cursor can resume `id` from `work_dir` (decision 6, live test R1)."
  def chat_exists?(id, work_dir, config \\ config_dir()) do
    is_binary(id) and Regex.match?(~r/\A[0-9A-Za-z][0-9A-Za-z-]{0,127}\z/, id) and
      [config, "chats", chat_key(work_dir), id, "meta.json"]
      |> Path.join()
      |> File.regular?()
  end

  @doc "Cursor keys chats by the MD5 of the resolved working directory."
  def chat_key(work_dir),
    do: :crypto.hash(:md5, realpath(work_dir)) |> Base.encode16(case: :lower)

  @doc false
  def realpath(path), do: resolve(tl(Path.split(Path.expand(path))), [], 0)

  defp resolve(_parts, _acc, depth) when depth > 40, do: raise(ArgumentError, "symlink loop")
  defp resolve([], acc, _depth), do: join(acc)
  defp resolve([".." | rest], acc, depth), do: resolve(rest, Enum.drop(acc, -1), depth)
  defp resolve(["." | rest], acc, depth), do: resolve(rest, acc, depth)

  defp resolve([part | rest], acc, depth) do
    candidate = join(acc ++ [part])

    case File.read_link(candidate) do
      {:ok, target} ->
        parts =
          if Path.type(target) == :absolute,
            do: tl(Path.split(target)),
            else: acc ++ Path.split(target)

        resolve(parts ++ rest, [], depth + 1)

      _ ->
        resolve(rest, acc ++ [part], depth)
    end
  end

  defp join([]), do: "/"
  defp join(parts), do: "/" <> Enum.join(parts, "/")

  @doc """
  Creates the run's private `HOME` with its MCP config and the configured
  links into the daemon's real `HOME`. Returns the home and warnings.
  """
  def prepare_home(spec, run_dir, links, real_home) do
    home = Paths.private_dir!(Path.join(run_dir, "home"))
    cursor = Paths.private_dir!(Path.join(home, ".cursor"))
    extra = spec.agent.extra_mcp_servers || %{}

    helmsman = %{
      "url" => spec.mcp.url,
      "headers" => %{"Authorization" => "Bearer " <> "${env:HELMSMAN_RUN_TOKEN}"}
    }

    config = %{"mcpServers" => Map.put(Map.delete(extra, "helmsman"), "helmsman", helmsman)}

    with :ok <- write_private(Path.join(cursor, "mcp.json"), JSON.encode!(config)),
         :ok <- link_all(links, home, real_home) do
      warnings =
        if Map.has_key?(extra, "helmsman"),
          do: ["Ignored extra MCP server named helmsman"],
          else: []

      {:ok, home, warnings}
    end
  end

  defp write_private(path, contents) do
    with {:ok, file} <- File.open(path, [:write, :exclusive]) do
      try do
        with :ok <- File.chmod(path, 0o600), do: IO.binwrite(file, contents)
      after
        File.close(file)
      end
    end
  end

  defp link_all(_links, _home, real_home) when real_home in [nil, ""], do: :ok

  defp link_all(links, home, real_home) do
    Enum.reduce_while(links, :ok, fn entry, :ok ->
      source = Path.join(real_home, entry)
      target = Path.join(home, entry)

      with {:ok, _} <- File.lstat(source),
           :ok <- File.mkdir_p(Path.dirname(target)),
           :ok <- File.ln_s(source, target) do
        {:cont, :ok}
      else
        {:error, :enoent} -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  @doc """
  Environment for the CLI (decision 5): `{set, unset, dropped Agent variable names}`.
  """
  def environment(env, agent_env, home) do
    drop? = fn name ->
      String.starts_with?(name, ["CURSOR_", "AGENT_CLI_"]) and name not in @kept
    end

    unset = env |> Map.keys() |> Enum.filter(drop?) |> Enum.sort()
    dropped = agent_env |> Map.keys() |> Enum.filter(drop?) |> Enum.sort()

    set = [
      {"HOME", home},
      {"CURSOR_CONFIG_DIR", config_dir()},
      {"CURSOR_DATA_DIR", data_dir()},
      {"AGENT_CLI_CREDENTIAL_STORE", "memory"},
      {"DIRENV_DISABLE", "1"}
    ]

    {set, unset, dropped}
  end
end
