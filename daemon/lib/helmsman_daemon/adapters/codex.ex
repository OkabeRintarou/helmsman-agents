defmodule HelmsmanDaemon.Adapters.Codex do
  @moduledoc "Unattended Codex app-server with a shared Codex home and per-thread MCP."
  @behaviour HelmsmanDaemon.Adapter
  alias HelmsmanDaemon.Adapters.Codex.{Config, Home, Output, Provider, Source, Vendor}
  alias HelmsmanDaemon.{Exec, Launch}
  @minimum Version.parse!("0.162.0")
  @efforts ~w(low medium high xhigh)
  def vendor, do: Vendor.infer()

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
         :ok <- validate_home(version) do
      {:ok, %{version: version, models: [], efforts: @efforts}}
    else
      {:error, "CLI executable not found"} -> {:error, "codex not found in PATH"}
      {:error, reason} -> {:error, reason}
      _ -> {:error, "Invalid Codex CLI version"}
    end
  end

  defp validate_home(version) do
    with {:ok, location} <- Home.resolve(), do: Config.validate(location, version)
  end

  defp supported(version) do
    if Version.compare(version, @minimum) == :lt,
      do: {:error, "Codex CLI version too old; requires #{@minimum}"},
      else: :ok
  end

  def prepare(spec, _run_dir, work_dir) do
    prepare(spec, nil, work_dir, HelmsmanDaemon.McpEnv.cli_env(System.get_env(), spec.agent.env))
  end

  def prepare(spec, _run_dir, work_dir, env) do
    with {:ok, location} <- Home.resolve(),
         {:ok, config} <- Config.read_validated(location),
         :ok <- Config.project_config(work_dir) do
      {extra, mcp_events} = HelmsmanDaemon.McpEnv.resolve(spec.agent.extra_mcp_servers, env)
      spec = %{spec | agent: %{spec.agent | extra_mcp_servers: extra}}
      home = Home.prepare(location)
      env = Map.put(Map.new(env), "CODEX_HOME", home)
      provider_result = check_provider(spec, home, env, config)

      provider_result =
        case provider_result do
          {:ok, warnings} -> {:ok, mcp_events ++ warnings}
          error -> error
        end

      finish_prepare(provider_result, spec, work_dir, location, config)
    else
      {:error, message} -> {:error, {:workspace_prepare, message}}
    end
  end

  defp finish_prepare(provider_result, spec, work_dir, location, config) do
    # The login subprocess can wait while the user edits their configuration.
    # Validate again and reject a changed snapshot before returning a Launch.
    case Config.unchanged(location, config) do
      :ok ->
        with {:ok, provider_warnings} <- provider_result do
          launch(spec, work_dir, location, Config.mcp_names(config), provider_warnings)
        end

      {:error, message} ->
        {:error, {:workspace_prepare, message}}
    end
  end

  defp check_provider(spec, home, env, config) do
    case Source.check(spec, home, env, config) do
      {:ok, _source} ->
        {:ok, Source.warnings(spec, config, env)}

      {:unknown, reason} ->
        {:ok, warning("Could not check the Codex login (#{inspect(reason)}); starting anyway.")}

      {:error, reason} ->
        {:error,
         {:provider_auth, "Codex agent #{spec.agent.name}: " <> Source.error(reason, home)}}
    end
  end

  defp launch(spec, work_dir, {_mode, home} = location, user_names, provider_warnings) do
    snapshot_warnings = Config.cleanup_snapshots(location)
    {servers, removed_servers} = Config.mcp(spec, user_names)

    {args, removed_args} =
      Config.filter(spec.agent.custom_args, not is_nil(spec.agent.provider_account))

    params =
      %{
        "cwd" => work_dir,
        "approvalPolicy" => "never",
        "sandbox" => "danger-full-access",
        "config" => %{
          "mcp_servers" => servers,
          # Codex 0.162.1 otherwise persists Git project trust on thread/start.
          # Thread overrides prevent that write; app-server CLI -c does not.
          "projects" => %{work_dir => %{"trust_level" => "trusted"}}
        }
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
         provider_warnings ++
           snapshot_warnings ++
           warnings("Ignored extra MCP servers", removed_servers) ++
           warnings("Ignored Codex arguments", removed_args) ++ Provider.warnings(spec.agent)
     }}
  end

  def optional(map, _key, value) when value in [nil, ""], do: map
  def optional(map, key, value), do: Map.put(map, key, value)
  def frame(value), do: JSON.encode!(Map.put(value, "jsonrpc", "2.0")) <> "\n"
  def warning(message), do: [{:status, %{level: :warning, message: message}}]
  defp warnings(_message, []), do: []

  defp warnings(message, removed),
    do: warning(message <> ": " <> Enum.join(Enum.uniq(removed), ", "))

  def init_state(spec), do: Output.init(spec)

  def init_state(spec, %Launch{stdin: frames}) do
    request = frames |> List.last() |> JSON.decode!()
    Output.init(spec, request["params"]["config"]["mcp_servers"])
  end

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

  # `add-codex-adapter` decision 12; the reply to the request settles
  # `ref` (`add-run-steering` decision 11).
  def steer(ref, text, %{turn_id: id, closed?: false} = state) when is_binary(id) do
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

    {:ok, bytes, :pending,
     %{state | next_steer: number + 1, pending_steers: Map.put(state.pending_steers, number, ref)}}
  end

  def steer(_ref, _text, _state), do: :unsupported
end
