defmodule HelmsmanDaemon.Adapters.Copilot.Probe do
  @moduledoc false
  require Logger
  alias HelmsmanDaemon.Adapters.Copilot.{Environment, Home}
  alias HelmsmanDaemon.{Env, Exec, LineBuffer, Paths, ProcGroup}

  @login "Copilot CLI is not logged in: run 'gh auth login' as the daemon's user, or set COPILOT_GITHUB_TOKEN"

  def detect(executable, executor) do
    executable = System.find_executable(executable) || executable

    with {:ok, _} <- Home.validate() do
      temporary(&detect_in(&1, executable, executor))
    end
  end

  defp detect_in(root, executable, executor) do
    env = Environment.clean(Env.child(), Path.join(root, "home"))
    logs = Path.join(root, "logs")
    version_args = [executable, "--version", "--no-auto-update", "--log-dir", logs]

    with {:ok, %{stdout: output, status: 0}} <-
           executor.(version_args, env: env, cd: Path.join(root, "work"), timeout: 10_000),
         [_, version] <- Regex.run(~r/(\d+\.\d+\.\d+)/, output),
         {:ok, parsed} <- Version.parse(version),
         :ok <- supported(parsed) do
      args = [
        executable,
        "--acp",
        "--no-auto-update",
        "--log-dir",
        logs,
        "--disable-builtin-mcps"
      ]

      result =
        executor.(args, env: env, cd: Path.join(root, "work"), timeout: 20_000, acp: true)

      detection(version, models(result))
    else
      {:error, reason} when is_binary(reason) -> {:error, reason}
      _ -> {:error, "Copilot CLI executable not found or invalid version"}
    end
  end

  defp detection(_version, {:error, :not_logged_in}), do: {:error, @login}

  defp detection(version, {:ok, models}),
    do: {:ok, %{version: version, models: models, efforts: ~w(low medium high xhigh max)}}

  defp temporary(fun) do
    root =
      Paths.private_dir!(
        Path.join(Paths.home(), "copilot-probe-#{System.unique_integer([:positive])}")
      )

    try do
      Enum.each(~w(home logs work), &Paths.private_dir!(Path.join(root, &1)))
      fun.(root)
    after
      File.rm_rf!(root)
    end
  end

  defp supported(version) do
    if Version.compare(version, Version.parse!("1.0.96")) == :lt,
      do: {:error, "Copilot CLI #{version} is older than 1.0.96"},
      else: :ok
  end

  defp models({:ok, result}) do
    replies =
      result.stdout
      |> String.split("\n", trim: true)
      |> Enum.flat_map(&decode_reply/1)

    reply = Enum.find(replies, &(&1["id"] == 2)) || %{}
    text = result.stderr <> " " <> JSON.encode!(reply["error"] || %{})

    cond do
      Regex.match?(~r/Authentication required|No authentication information found/i, text) ->
        {:error, :not_logged_in}

      is_map(reply["result"]) ->
        models = get_in(reply, ["result", "models", "availableModels"]) || []
        {:ok, for(%{"modelId" => id} <- models, is_binary(id), do: id)}

      true ->
        fallback()
    end
  end

  defp models(_), do: fallback()

  defp decode_reply(line) do
    case JSON.decode(line) do
      {:ok, value} when is_map(value) -> [value]
      _ -> []
    end
  end

  defp fallback do
    Logger.warning("Copilot ACP model probe failed or timed out; using the CLI default model")
    {:ok, []}
  end

  def command(argv, opts) do
    caller = self()
    ref = make_ref()

    {pid, monitor} =
      spawn_monitor(fn ->
        owner = Process.monitor(caller)
        result = execute(argv, opts, owner)
        send(caller, {ref, result})
      end)

    receive do
      {^ref, result} ->
        Process.demonitor(monitor, [:flush])
        result

      {:DOWN, ^monitor, :process, ^pid, _} ->
        {:error, :probe_exited}
    end
  end

  defp execute(argv, opts, owner) do
    options = [
      :stdin,
      :stdout,
      :stderr,
      :monitor,
      {:group, 0},
      :kill_group,
      {:kill_timeout, 0},
      {:env, [:clear | Enum.to_list(Keyword.fetch!(opts, :env))]},
      {:cd, Keyword.fetch!(opts, :cd)}
    ]

    case Exec.run_cli(argv, options) do
      {:ok, exec_pid, pid, _guardian} ->
        {:ok, members} = ProcGroup.snapshot(pid)

        try do
          if callback = opts[:on_start], do: callback.(pid)
          if opts[:acp], do: :exec.send(pid, frame(initialize())), else: :exec.send(pid, :eof)

          state = %{
            stdout: "",
            stderr: "",
            buffer: LineBuffer.new(),
            sent_new?: false,
            deadline: System.monotonic_time(:millisecond) + Keyword.fetch!(opts, :timeout)
          }

          collect(exec_pid, pid, owner, opts, state)
        after
          :ok = ProcGroup.recover(pid, members, cleanup_timeout_ms: 10_000)
        end

      _ ->
        {:error, :launch}
    end
  end

  defp collect(exec_pid, pid, owner, opts, state) do
    receive do
      {:stdout, ^pid, data} ->
        next = %{state | stdout: state.stdout <> data}

        if byte_size(next.stdout) > 1_048_576 do
          stop(exec_pid, pid)
          {:error, :output_limit}
        else
          next = if opts[:acp], do: handshake(pid, data, opts, next), else: next
          collect(exec_pid, pid, owner, opts, next)
        end

      {:stderr, ^pid, data} ->
        collect(exec_pid, pid, owner, opts, %{
          state
          | stderr: String.slice(state.stderr <> data, -65_536, 65_536)
        })

      {:DOWN, _, :process, ^exec_pid, reason} ->
        status = if reason == :normal, do: 0, else: reason
        {:ok, %{stdout: state.stdout, stderr: state.stderr, status: status}}

      {:DOWN, ^owner, :process, _, _} ->
        stop(exec_pid, pid)
        {:error, :owner_down}
    after
      max(state.deadline - System.monotonic_time(:millisecond), 0) ->
        stop(exec_pid, pid)
        {:error, :timeout}
    end
  end

  defp handshake(pid, data, opts, state) do
    {lines, buffer} = LineBuffer.push(state.buffer, data, 1_048_576)
    Enum.reduce(lines, %{state | buffer: buffer}, &reply(&1, &2, pid, opts))
  end

  defp reply(:overflow, state, _pid, _opts), do: state

  defp reply(line, state, pid, opts) do
    case JSON.decode(line) do
      {:ok, %{"id" => 1, "result" => _}} when not state.sent_new? ->
        :exec.send(
          pid,
          frame(%{
            "id" => 2,
            "method" => "session/new",
            "params" => %{"cwd" => opts[:cd], "mcpServers" => []}
          })
        )

        %{state | sent_new?: true}

      {:ok, %{"id" => id}} when id in [1, 2] ->
        :exec.send(pid, :eof)
        state

      _ ->
        state
    end
  end

  defp stop(exec_pid, pid) do
    Exec.signal_group(pid, 15)

    receive do
      {:DOWN, _, :process, ^exec_pid, _} -> :ok
    after
      10_000 -> Exec.signal_group(pid, 9)
    end
  end

  defp frame(value), do: JSON.encode!(Map.put(value, "jsonrpc", "2.0")) <> "\n"

  defp initialize,
    do: %{
      "id" => 1,
      "method" => "initialize",
      "params" => %{
        "protocolVersion" => 1,
        "clientCapabilities" => %{
          "fs" => %{"readTextFile" => false, "writeTextFile" => false},
          "terminal" => false
        },
        "clientInfo" => %{"name" => "helmsman-daemon", "version" => "0.1.0"}
      }
    }
end
