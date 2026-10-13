defmodule HelmsmanDaemon.Adapters.Cursor do
  @moduledoc """
  Cursor CLI (`cursor-agent -p`) with a private `HOME` per run, private
  config and data directories, an API key only, and descendant tracking
  (`add-cursor-adapter`). Off unless the daemon config has
  `[cursor] enabled = true` (decision 1).
  """
  @behaviour HelmsmanDaemon.Adapter
  require Logger
  alias HelmsmanDaemon.Adapters.Cursor.{Args, Home, Output}
  alias HelmsmanDaemon.{Env, Exec, Launch, Paths}

  @minimum Version.parse!("2026.10.1")
  @detect_timeout 30_000

  def provider, do: :cursor

  def executable,
    do: Application.get_env(:helmsman_daemon, :cursor_executable, "cursor-agent")

  def min_version, do: @minimum
  def track_descendants?, do: true

  ## Detection (decision 2)

  def detect, do: detect(Home.config(), System.get_env(), &run/3)

  @doc """
  `runner.(path, args, opts)` runs the CLI (`opts`: `:env`, `:cd`,
  `:timeout`) and returns `{:ok, output}` or `{:error, {reason, output}}`.
  """
  def detect(config, env, runner) do
    with :ok <- Home.usable(config),
         {:ok, path} <- find_executable() do
      deadline = System.monotonic_time(:millisecond) + @detect_timeout
      scratch = Paths.private_dir!(Path.join(Paths.cursor_root(), "detect-#{random(4)}"))

      try do
        probe(path, env, scratch, runner, deadline)
      after
        File.rm_rf(scratch)
      end
    end
  end

  defp find_executable do
    case System.find_executable(executable()) do
      nil -> {:error, "cursor-agent not found in PATH"}
      path -> {:ok, path}
    end
  end

  defp probe(path, env, scratch, runner, deadline) do
    dirs =
      Map.new(~w(home config data work tmp), &{&1, Paths.private_dir!(Path.join(scratch, &1))})

    cli_env =
      env
      |> Env.child()
      |> Map.reject(fn {name, _} ->
        String.starts_with?(name, ["CURSOR_", "AGENT_CLI_"]) and
          name not in ["CURSOR_API_KEY", "CURSOR_API_ENDPOINT"]
      end)
      |> Map.merge(%{
        "HOME" => dirs["home"],
        "CURSOR_CONFIG_DIR" => dirs["config"],
        "CURSOR_DATA_DIR" => dirs["data"],
        "TMPDIR" => dirs["tmp"],
        "AGENT_CLI_CREDENTIAL_STORE" => "memory",
        "DIRENV_DISABLE" => "1"
      })

    command = fn args ->
      remaining = deadline - System.monotonic_time(:millisecond)

      if remaining <= 0,
        do: {:error, {:timeout, ""}},
        else: runner.(path, args, env: cli_env, cd: dirs["work"], timeout: remaining)
    end

    with {:ok, version} <- version(command.(["--version"])),
         :ok <- api_key(env),
         :ok <- warn_data_dir() do
      case servers(command.(["mcp", "list"])) do
        :timeout -> {:ok, detection(version, [])}
        {:error, _} = error -> error
        :ok -> models(version, command.(["--list-models"]))
      end
    end
  end

  defp version({:ok, output}) do
    with [_, year, month, day] <- Regex.run(~r/^(\d+)\.(\d+)\.(\d+)/, String.trim(output)),
         version =
           Enum.map_join([year, month, day], ".", &Integer.to_string(String.to_integer(&1))),
         {:ok, parsed} <- Version.parse(version) do
      if Version.compare(parsed, @minimum) == :lt,
        do: {:error, "Cursor CLI version too old; requires #{@minimum}"},
        else: {:ok, version}
    else
      _ -> {:error, "Invalid Cursor CLI version"}
    end
  end

  defp version({:error, {:timeout, _}}), do: {:error, "Cursor CLI version command timed out"}
  defp version({:error, _}), do: {:error, "Cursor CLI version command failed"}

  defp api_key(env) do
    if is_binary(env["CURSOR_API_KEY"]) and env["CURSOR_API_KEY"] != "",
      do: :ok,
      else: {:error, "set CURSOR_API_KEY for the daemon (agent login is not supported)"}
  end

  defp warn_data_dir do
    if byte_size(Home.data_dir()) > 70,
      do:
        Logger.warning(
          "Cursor's data directory path is longer than 70 bytes; its worker socket will be placed under /tmp/.cursor"
        )

    :ok
  end

  # Live test R4: one `<name>: <status>` line per server.
  defp servers({:ok, output}) do
    names =
      for line <- String.split(output, "\n"),
          [_, name] <- [Regex.run(~r/^([^\s:][^:]*): \S/, String.trim_trailing(line))],
          do: name

    if names == [],
      do: :ok,
      else:
        {:error,
         "Cursor loads MCP servers Helmsman did not configure (team policy from the Cursor dashboard?): " <>
           Enum.join(names, ", ")}
  end

  defp servers({:error, {:timeout, _}}), do: :timeout
  defp servers({:error, {_reason, output}}), do: {:error, failure("mcp list", output)}

  defp models(version, {:ok, output}) do
    models =
      for line <- String.split(output, "\n"),
          [_, id] <- [Regex.run(~r/^(\S+) - /, line)],
          do: id

    {:ok, detection(version, models)}
  end

  defp models(version, {:error, {:timeout, _}}), do: {:ok, detection(version, [])}

  defp models(_version, {:error, {_reason, output}}),
    do: {:error, failure("--list-models", output)}

  defp failure(command, output) do
    tail = output |> String.split("\n", trim: true) |> Enum.take(-3) |> Enum.join(" ")

    case Output.classify(output) do
      :provider_auth -> "Cursor rejected CURSOR_API_KEY: " <> tail
      :provider_network -> "Cursor API unreachable: " <> tail
      _ -> "cursor-agent #{command} failed: " <> tail
    end
  end

  defp detection(version, models), do: %{version: version, models: models, efforts: []}

  defp run(path, args, opts) do
    Exec.command([path | args], opts)
  end

  ## Launch (decisions 3–6, 8, 10)

  def prepare(spec, run_dir, work_dir),
    do: prepare(spec, run_dir, work_dir, Env.agent(System.get_env(), spec.agent.env))

  def prepare(spec, run_dir, work_dir, env) do
    config = Home.config()

    with :ok <- Home.usable(config),
         :ok <- Home.ensure_dirs!(),
         :ok <- Home.check_approvals(),
         {:ok, session} <- session(spec, work_dir),
         {:ok, home, warnings} <-
           Home.prepare_home(spec, run_dir, config.home_links, System.get_env("HOME")) do
      {set, unset, dropped} = Home.environment(Map.new(env), spec.agent.env, home)
      {custom, removed} = Args.filter(spec.agent.custom_args)

      warnings =
        warnings ++
          if(dropped == [],
            do: [],
            else: ["Ignored Cursor environment variables: " <> Enum.join(dropped, ", ")]
          ) ++
          if removed == [],
            do: [],
            else: ["Ignored conflicting Cursor arguments: " <> Enum.join(removed, ", ")]

      {:ok,
       %Launch{
         argv:
           [
             System.find_executable(executable()) || executable(),
             "-p",
             "--force",
             "--output-format",
             "stream-json",
             "--sandbox",
             "disabled",
             "--disable-codebase-ref",
             "--disable-project-configs",
             "--model",
             spec.agent.model || "auto"
           ] ++ session ++ custom,
         env: set,
         drop_env: unset,
         stdin: spec.prompt,
         close_stdin?: true,
         track_descendants: true,
         events: Enum.map(warnings, &{:status, %{level: :warning, message: &1}})
       }}
    else
      {:error, {reason, message}} when is_atom(reason) ->
        {:error, {reason, message}}

      {:error, message} when is_binary(message) ->
        {:error, {:cli_error, message}}

      {:error, reason} ->
        {:error,
         {:workspace_prepare, "Could not prepare Cursor's private home: #{inspect(reason)}"}}
    end
  end

  defp session(%{resume_session_id: id}, work_dir) when is_binary(id) do
    if Home.chat_exists?(id, work_dir),
      do: {:ok, ["--resume", id]},
      else: {:error, {:cli_error, "the Cursor chat #{id} can no longer be resumed"}}
  end

  defp session(_spec, _work_dir), do: {:ok, ["--new-session-id", uuid()]}

  defp uuid do
    <<a::48, _::4, b::12, _::2, c::62>> = :crypto.strong_rand_bytes(16)
    hex = Base.encode16(<<a::48, 4::4, b::12, 2::2, c::62>>, case: :lower)

    Enum.join(
      [
        binary_part(hex, 0, 8),
        binary_part(hex, 8, 4),
        binary_part(hex, 12, 4),
        binary_part(hex, 16, 4),
        binary_part(hex, 20, 12)
      ],
      "-"
    )
  end

  defp random(bytes), do: Base.encode16(:crypto.strong_rand_bytes(bytes), case: :lower)

  ## Output (decisions 7, 9, 11)

  def init_state(spec), do: Output.init(spec, nil)

  def init_state(spec, %Launch{argv: argv}) do
    session =
      case Enum.drop_while(argv, &(&1 not in ["--new-session-id", "--resume"])) do
        [_flag, id | _] -> id
        _ -> nil
      end

    Output.init(spec, session)
  end

  def handle_output(stream, line, state), do: Output.handle(stream, line, state)
  def finish(code, state), do: Output.finish(code, state)
  def interrupt(_state), do: :signal
  def steer(_ref, _text, _state), do: :unsupported
end
