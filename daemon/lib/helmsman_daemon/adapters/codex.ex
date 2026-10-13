defmodule HelmsmanDaemon.Adapters.Codex do
  @moduledoc "Unattended Codex app-server with a persistent daemon home and per-thread MCP."
  @behaviour HelmsmanDaemon.Adapter
  alias HelmsmanDaemon.Adapters.Codex.{Config, Output, Provider}
  alias HelmsmanDaemon.{Exec, Launch, Paths}
  @minimum Version.parse!("0.162.0")
  @efforts ~w(low medium high xhigh)
  def provider, do: :codex
  def executable, do: Application.get_env(:helmsman_daemon, :codex_executable, "codex")
  def min_version, do: @minimum
  def max_line_bytes, do: 32 * 1_048_576
  def detect, do: detect(&Exec.version/1)

  def detect(probe) do
    with {:ok, output} <- probe.(executable()),
         [_, version] <- Regex.run(~r/(\d+\.\d+\.\d+)/, output),
         {:ok, parsed} <- Version.parse(version),
         :ok <- supported(parsed),
         :ok <- Config.validate() do
      {:ok, %{version: version, models: [], efforts: @efforts}}
    else
      {:error, "CLI executable not found"} -> {:error, "codex not found in PATH"}
      {:error, reason} -> {:error, reason}
      _ -> {:error, "Invalid Codex CLI version"}
    end
  end

  defp supported(version) do
    if Version.compare(version, @minimum) == :lt,
      do: {:error, "Codex CLI version too old; requires #{@minimum}"},
      else: :ok
  end

  def prepare(spec, _run_dir, work_dir) do
    with :ok <- Config.validate(), :ok <- Config.project_config(work_dir) do
      home = Paths.private_dir!(Config.home())
      snapshot_warnings = Config.cleanup_snapshots(home)
      {servers, removed_servers} = Config.mcp(spec)

      {args, removed_args} =
        Config.filter(spec.agent.custom_args, not is_nil(spec.agent.provider_account))

      params =
        %{
          "cwd" => work_dir,
          "approvalPolicy" => "never",
          "sandbox" => "danger-full-access",
          "config" => %{"mcp_servers" => servers}
        }
        |> optional("model", Provider.model(spec.agent))

      {method, params} =
        if spec.resume_session_id,
          do: {"thread/resume", Map.put(params, "threadId", spec.resume_session_id)},
          else: {"thread/start", params}

      stdin = [
        frame(%{
          "id" => 1,
          "method" => "initialize",
          "params" => %{
            "clientInfo" => %{
              "name" => "helmsman-daemon",
              "title" => "Helmsman daemon",
              "version" => to_string(Application.spec(:helmsman_daemon, :vsn) || "0.1.0")
            }
          }
        }),
        frame(%{"method" => "initialized"}),
        frame(%{"id" => 2, "method" => method, "params" => params})
      ]

      {:ok,
       %Launch{
         argv:
           [
             System.find_executable(executable()) || executable(),
             "app-server",
             "--disable",
             "shell_snapshot",
             "--disable",
             "shell_snapshot_v2",
             "-c",
             "check_for_update_on_startup=false"
           ] ++ Provider.argv(spec.agent.provider_account) ++ args,
         env: [{"CODEX_HOME", home}] ++ Provider.env(spec.agent.provider_account),
         stdin: stdin,
         close_stdin?: false,
         events:
           snapshot_warnings ++
             warnings("Ignored extra MCP servers", removed_servers) ++
             warnings("Ignored Codex arguments", removed_args) ++ Provider.warnings(spec.agent)
       }}
    else
      {:error, message} -> {:error, {:workspace_prepare, message}}
    end
  end

  def optional(map, _key, value) when value in [nil, ""], do: map
  def optional(map, key, value), do: Map.put(map, key, value)
  def frame(value), do: JSON.encode!(Map.put(value, "jsonrpc", "2.0")) <> "\n"
  def warning(message), do: [{:status, %{level: :warning, message: message}}]
  defp warnings(_message, []), do: []

  defp warnings(message, removed),
    do: warning(message <> ": " <> Enum.join(Enum.uniq(removed), ", "))

  def init_state(spec), do: Output.init(spec)
  def handle_output(stream, line, state), do: Output.handle(stream, line, state)
  def finish(code, state), do: Output.finish(code, state)

  def interrupt(%{turn_id: id, closed?: false} = state) when is_binary(id),
    do:
      {:write,
       frame(%{
         "id" => "interrupt",
         "method" => "turn/interrupt",
         "params" => %{"threadId" => state.session_id, "turnId" => id}
       })}

  def interrupt(_), do: :signal

  def steer(text, %{turn_id: id, closed?: false} = state) when is_binary(id) do
    number = state.next_steer

    bytes =
      frame(%{
        "id" => number,
        "method" => "turn/steer",
        "params" => %{
          "threadId" => state.session_id,
          "expectedTurnId" => id,
          "input" => [%{"type" => "text", "text" => text}]
        }
      })

    {:ok, bytes,
     %{state | next_steer: number + 1, pending_steers: MapSet.put(state.pending_steers, number)}}
  end

  def steer(_, _), do: :unsupported
end
