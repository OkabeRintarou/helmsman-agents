defmodule HelmsmanDaemon.CLI do
  @moduledoc """
  Command line of the installed `helmsman` binary and of `mix helmsman`.

  Exit codes: 0 success, 1 general error, 2 usage, 3 authentication failure /
  daemon not running / service manager unavailable, 4 protocol incompatible,
  5 no usable agent CLI.
  """
  alias HelmsmanDaemon.{
    Config,
    Credentials,
    Detector,
    EnvFile,
    LocalRepos,
    LogFile,
    Login,
    Paths,
    Release,
    Service
  }

  @usage [
    "helmsman --version",
    "helmsman login --server URL [--force]",
    "helmsman logout",
    "helmsman runtimes",
    "helmsman daemon start [--foreground]",
    "helmsman daemon stop",
    "helmsman daemon restart",
    "helmsman daemon status [--json]",
    "helmsman daemon logs [-f] [-n N]",
    "helmsman repos add PATH --name NAME --workspace SLUG...",
    "helmsman repos remove NAME",
    "helmsman repos list"
  ]

  def main(args), do: System.stop(run(args))

  def run(args, opts \\ []) do
    case OptionParser.parse(args,
           strict: [
             server: :string,
             force: :boolean,
             foreground: :boolean,
             service: :boolean,
             json: :boolean,
             follow: :boolean,
             lines: :integer,
             version: :boolean,
             name: :string,
             workspace: :keep
           ],
           aliases: [f: :follow, n: :lines]
         ) do
      {[version: true], [], []} ->
        IO.puts(
          Release.version_line(Keyword.get_lazy(opts, :standalone?, &Release.standalone?/0))
        )

        0

      {flags, command, []} ->
        case HelmsmanDaemon.Exec.ensure_started() do
          :ok ->
            dispatch(command, flags, opts)

          {:error, reason} ->
            IO.puts("Could not start the process helper (erlexec): #{inspect(reason)}")
            1
        end

      _ ->
        usage()
    end
  end

  @doc "Usage text; every subcommand in the documentation must appear here."
  def usage_text do
    Enum.join(
      ["Usage:" | Enum.map(@usage, &("  " <> &1))] ++
        [
          "",
          "`daemon start` installs and starts the background service (systemd user",
          "service or launchd agent); --foreground runs in this terminal or under",
          "your own supervisor. The service runs `daemon start --foreground --service`."
        ],
      "\n"
    )
  end

  defp dispatch(["runtimes"], [], _opts) do
    case Config.load() do
      {:ok, _} ->
        print_clis()

        case Credentials.metadata() do
          {:ok, credentials} -> Login.print_workspaces(credentials.workspaces)
          _ -> IO.puts("Not logged in")
        end

        0

      _ ->
        IO.puts("Invalid config.toml")
        1
    end
  end

  defp dispatch(["login"], flags, opts) do
    if flags[:server] && Keyword.keys(flags) -- [:server, :force] == [],
      do: Login.login(flags[:server], Keyword.merge(opts, force: flags[:force] || false)),
      else: usage()
  end

  defp dispatch(["logout"], [], opts) do
    case Service.stop_if_enabled(opts) do
      :ok -> Login.logout(opts)
      {:error, code} -> code
    end
  end

  defp dispatch(["daemon", "start"], flags, opts) do
    cond do
      Keyword.keys(flags) -- [:foreground, :service] != [] -> usage()
      flags[:service] && !flags[:foreground] -> usage()
      flags[:foreground] -> foreground(flags[:service] || false, opts)
      true -> Service.start(opts)
    end
  end

  defp dispatch(["daemon", "stop"], [], opts), do: Service.stop(opts)
  defp dispatch(["daemon", "restart"], [], opts), do: Service.restart(opts)

  defp dispatch(["daemon", "status"], flags, opts) do
    if Keyword.keys(flags) -- [:json] == [],
      do: Service.status(Keyword.put(opts, :json, flags[:json] || false)),
      else: usage()
  end

  defp dispatch(["daemon", "logs"], flags, opts) do
    lines = Keyword.get(flags, :lines, 100)

    if Keyword.keys(flags) -- [:follow, :lines] == [] and lines > 0,
      do: Service.logs(lines, flags[:follow] || false, opts),
      else: usage()
  end

  defp dispatch(["repos", "add", path], flags, opts) do
    if flags[:name] && Enum.uniq(Keyword.keys(flags)) -- [:name, :workspace] == [] do
      Paths.ensure!()

      case LocalRepos.add(path, flags[:name], Keyword.get_values(flags, :workspace), opts) do
        :ok ->
          IO.puts("Added local repository #{flags[:name]}")
          print_repos(opts)

        {:error, message} ->
          IO.puts(message)
          1
      end
    else
      usage()
    end
  end

  defp dispatch(["repos", "remove", name], [], opts) do
    Paths.ensure!()

    case LocalRepos.remove(name, opts) do
      :ok ->
        IO.puts("Removed local repository #{name}")
        0

      {:error, message} ->
        IO.puts(message)
        1
    end
  end

  defp dispatch(["repos", "list"], [], opts) do
    Paths.ensure!()
    print_repos(opts)
  end

  defp dispatch(_, _, _), do: usage()

  defp print_repos(opts) do
    case LocalRepos.list_lines(opts) do
      {:ok, lines} ->
        Enum.each(lines, &IO.puts/1)
        0

      {:error, message} ->
        IO.puts(message)
        1
    end
  end

  defp print_clis do
    Enum.each(Detector.scan(), fn cli ->
      availability = if cli.available, do: "available", else: cli.unavailable_reason
      IO.puts("#{cli.provider}: #{cli.version || "unknown"} #{availability}")

      if cli.provider == :codex do
        IO.puts(
          "Codex uses inherited CODEX_HOME or $HOME/.codex by default; set [codex] home in daemon config.toml for a private directory. User MCP servers are disabled; rename a user helmsman MCP server. Use Agent env for credentials; -c values are visible in process arguments."
        )
      end
    end)
  end

  @doc """
  Checks shared by foreground and background start: a usable agent CLI (exit 5)
  and readable credentials (exit 1).
  """
  def preflight(opts) do
    adapters = Keyword.get(opts, :adapters, HelmsmanDaemon.Adapter.registered())

    if Detector.available?(Detector.scan(adapters)) do
      case Credentials.read() do
        {:ok, _} -> :ok
        {:error, reason} -> credentials_failure(reason)
      end
    else
      IO.puts("Install a supported agent CLI before starting the daemon")
      5
    end
  end

  defp credentials_failure({:keychain, _}), do: fail(Credentials.locked_message())
  defp credentials_failure(:invalid_config), do: fail("Invalid config.toml")
  defp credentials_failure(_), do: fail("Not logged in; run `helmsman login --server URL` first")

  defp fail(message) do
    IO.puts(message)
    1
  end

  defp foreground(service?, opts) do
    if service? do
      Paths.ensure!()
      LogFile.setup(Keyword.get_lazy(opts, :platform, &HelmsmanDaemon.Platform.os/0))
      EnvFile.load()
    end

    with :ok <- preflight(opts), do: run_daemon(opts)
  end

  defp run_daemon(opts) do
    case HelmsmanDaemon.start_daemon(opts) do
      {:ok, supervisor} ->
        ref = Process.monitor(supervisor)

        receive do
          {:DOWN, ^ref, _, _, _} -> if HelmsmanDaemon.stopping?(), do: 0, else: 1
        end

      {:error, _} ->
        IO.puts("Could not start daemon; check config and login")
        1
    end
  end

  defp usage do
    IO.puts(usage_text())
    2
  end
end
