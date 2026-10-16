defmodule HelmsmanDaemon.Adapters.Copilot do
  @moduledoc "Isolated Copilot CLI sessions with unattended JSONL output."
  @behaviour HelmsmanDaemon.Adapter
  alias HelmsmanDaemon.Adapters.Copilot.{Args, Environment, Home, Output, Probe}
  alias HelmsmanDaemon.{AtomicFile, Launch, Paths}
  @minimum Version.parse!("1.0.96")

  def provider, do: :copilot
  def executable, do: Application.get_env(:helmsman_daemon, :copilot_executable, "copilot")
  def min_version, do: @minimum
  def detect, do: detect(&Probe.command/2)
  def detect(executor), do: Probe.detect(executable(), executor)

  def prepare(spec, run_dir, work_dir),
    do:
      prepare(
        spec,
        run_dir,
        work_dir,
        HelmsmanDaemon.McpEnv.cli_env(System.get_env(), spec.agent.env)
      )

  def prepare(spec, run_dir, _work_dir, env) do
    case Home.validate() do
      {:ok, home} -> launch(spec, run_dir, env, home)
      {:error, message} -> {:error, {:cli_error, message}}
    end
  end

  defp launch(spec, run_dir, env, home) do
    Paths.private_dir!(run_dir)
    logs = Paths.private_dir!(Path.join(run_dir, "copilot-logs"))
    path = Path.join(run_dir, "mcp.json")
    {extra, mcp_events} = HelmsmanDaemon.McpEnv.resolve(spec.agent.extra_mcp_servers, env)

    servers =
      extra
      |> Map.delete("helmsman")
      |> Map.new(fn {name, config} ->
        {name, Map.put(config, "disableToolCache", true)}
      end)

    own = %{
      "type" => "http",
      "url" => spec.mcp.url,
      "headers" => %{"Authorization" => "Bearer ${HELMSMAN_RUN_TOKEN}"},
      "tools" => ["*"],
      "disableToolCache" => true
    }

    :ok =
      AtomicFile.write(path, JSON.encode!(%{"mcpServers" => Map.put(servers, "helmsman", own)}))

    {args, removed} = Args.filter(spec.agent.custom_args)

    session =
      if spec.resume_session_id,
        do: ["--resume", spec.resume_session_id],
        else: ["--session-id", uuid()]

    dropped = env |> Map.new() |> Map.keys() |> Enum.filter(&Environment.drop?/1)

    warnings =
      mcp_events ++
        warning("Ignored Copilot arguments", removed) ++
        warning(
          "Ignored extra MCP servers",
          if(Map.has_key?(extra, "helmsman"), do: ["helmsman"], else: [])
        ) ++
        env_warnings(spec.agent.env)

    {:ok,
     %Launch{
       argv:
         [
           System.find_executable(executable()) || executable(),
           "--output-format",
           "json",
           "--allow-all",
           "--no-ask-user",
           "--disable-builtin-mcps",
           "--additional-mcp-config",
           "@" <> path
         ] ++
           session ++
           optional("--model", spec.agent.model) ++
           optional("--reasoning-effort", spec.agent.effort) ++
           ["--no-auto-update", "--log-dir", logs] ++ args,
       env: [
         {"COPILOT_HOME", home},
         {"COPILOT_AUTO_UPDATE", "false"},
         {"HELMSMAN_RUN_TOKEN", spec.mcp.token}
       ],
       drop_env: dropped,
       stdin: spec.prompt,
       close_stdin?: true,
       events: warnings
     }}
  end

  defp env_warnings(env) do
    env
    |> Map.keys()
    |> Enum.sort()
    |> Enum.filter(&Environment.drop?/1)
    |> Enum.flat_map(&warning("Ignored Copilot environment variable", [&1]))
  end

  defp optional(_, value) when value in [nil, ""], do: []
  defp optional(flag, value), do: [flag, value]
  defp warning(_, []), do: []

  defp warning(prefix, names),
    do: [{:status, %{level: :warning, message: prefix <> ": " <> Enum.join(names, ", ")}}]

  defp uuid do
    <<a::32, b::16, _::4, c::12, _::2, d::14, e::48>> = :crypto.strong_rand_bytes(16)

    <<a::32, b::16, 4::4, c::12, 2::2, d::14, e::48>>
    |> Base.encode16(case: :lower)
    |> then(fn hex ->
      <<a::binary-size(8), b::binary-size(4), c::binary-size(4), d::binary-size(4), e::binary>> =
        hex

      Enum.join([a, b, c, d, e], "-")
    end)
  end

  def init_state(spec), do: Output.init(spec, spec.resume_session_id)

  def init_state(spec, launch) do
    index = Enum.find_index(launch.argv, &(&1 in ["--session-id", "--resume"]))
    Output.init(spec, Enum.at(launch.argv, index + 1))
  end

  defdelegate handle_output(stream, line, state), to: Output, as: :handle
  defdelegate finish(code, state), to: Output
  def interrupt(_), do: :signal
  def steer(_, _, _), do: :unsupported
end
