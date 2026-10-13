defmodule HelmsmanDaemon.CLI do
  @moduledoc "Foreground daemon and local device management commands."
  alias HelmsmanDaemon.{Config, Credentials, Detector, LocalRepos, Login, Paths}
  @background "后台服务随后续版本提供"

  def main(args), do: System.stop(run(args))

  def run(args, opts \\ []) do
    case OptionParser.parse(args,
           strict: [
             server: :string,
             force: :boolean,
             foreground: :boolean,
             name: :string,
             workspace: :keep
           ]
         ) do
      {flags, command, []} -> dispatch(command, flags, opts)
      _ -> usage()
    end
  end

  defp dispatch(["runtimes"], [], _opts) do
    case Config.load() do
      {:ok, _} ->
        print_clis()

        case Credentials.read() do
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

  defp dispatch(["logout"], [], opts), do: Login.logout(opts)

  defp dispatch(["daemon", "start"], flags, opts) do
    if Keyword.keys(flags) -- [:foreground] == [] do
      IO.puts(@background)
      start(opts)
    else
      usage()
    end
  end

  defp dispatch(["daemon", command], _flags, _opts)
       when command in ~w(stop restart status logs) do
    IO.puts(@background)
    2
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

  defp start(opts) do
    if Detector.available?(
         Detector.scan(Keyword.get(opts, :adapters, HelmsmanDaemon.Adapter.registered()))
       ) do
      case HelmsmanDaemon.start_daemon(opts) do
        {:ok, supervisor} ->
          ref = Process.monitor(supervisor)

          receive do
            {:DOWN, ^ref, _, _, _} -> 1
          end

        {:error, _} ->
          IO.puts("Could not start daemon; check config and login")
          1
      end
    else
      IO.puts("Install a supported agent CLI before starting the daemon")
      5
    end
  end

  defp usage do
    IO.puts(
      "Usage: helmsman login --server URL [--force] | logout | runtimes | daemon start [--foreground]" <>
        " | repos add PATH --name NAME --workspace SLUG... | repos remove NAME | repos list"
    )

    2
  end
end
