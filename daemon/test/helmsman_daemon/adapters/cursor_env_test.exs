defmodule HelmsmanDaemon.Adapters.CursorEnvTest do
  use HelmsmanDaemon.Case
  @moduletag :tmp_dir
  alias HelmsmanDaemon.Adapters.Cursor.Home
  alias HelmsmanDaemon.RunWorker

  defmodule DumpEnv do
    @moduledoc false
    alias HelmsmanDaemon.Adapters.{Cursor, Fake}
    defdelegate init_state(spec), to: Fake
    defdelegate handle_output(stream, line, state), to: Fake
    defdelegate finish(status, state), to: Fake
    defdelegate interrupt(state), to: Fake

    def prepare(spec, run_dir, work_dir, env) do
      with {:ok, launch} <- Cursor.prepare(spec, run_dir, work_dir, env) do
        scenario = Path.join(run_dir, "dump")
        File.write!(scenario, "dump_env\n")
        {:ok, %{launch | argv: [Fake.executable(), "--scenario", scenario], stdin: nil}}
      end
    end
  end

  setup do
    File.write!(Path.join(Paths.home(), "config.toml"), "[cursor]\nenabled = true\n")
    :ok
  end

  @tag skip: if(:os.type() != {:unix, :linux}, do: "descendant tracking needs Linux /proc")
  test "the CLI gets private directories, the Agent's key and none of the other Cursor variables" do
    previous =
      Map.take(System.get_env(), ["CURSOR_DATA_DIR", "AGENT_CLI_LOG_PATH", "CURSOR_API_KEY"])

    System.put_env(%{
      "CURSOR_DATA_DIR" => "/inherited/data",
      "AGENT_CLI_LOG_PATH" => "/inherited/log",
      "CURSOR_API_KEY" => "daemon-key"
    })

    on_exit(fn ->
      Enum.each(
        Map.keys(previous) ++ ["CURSOR_DATA_DIR", "AGENT_CLI_LOG_PATH", "CURSOR_API_KEY"],
        &System.delete_env/1
      )

      System.put_env(previous)
    end)

    start_execution()
    run = spec(7)

    run = %{
      run
      | agent: %{
          run.agent
          | provider: :cursor,
            custom_args: [],
            env: %{
              "CURSOR_CONFIG_DIR" => "/x",
              "CURSOR_API_KEY" => "agent-key",
              "AGENT_CLI_FOO" => "1"
            }
        }
    }

    start_supervised!({RunWorker, {run, [adapter: DumpEnv, reporter: TestReporter]}})
    {env, events} = collect(7, %{}, [])

    assert env["CURSOR_CONFIG_DIR"] == Home.config_dir()
    assert env["CURSOR_DATA_DIR"] == Home.data_dir()
    assert env["HOME"] == Path.join(Paths.run(7), "home")
    assert env["CURSOR_API_KEY"] == "agent-key"
    assert env["AGENT_CLI_CREDENTIAL_STORE"] == "memory"
    assert env["DIRENV_DISABLE"] == "1"
    refute Map.has_key?(env, "AGENT_CLI_LOG_PATH")
    refute Map.has_key?(env, "AGENT_CLI_FOO")
    assert env["HELMSMAN_PROC_TAG"] =~ ~r/\A7\.[0-9a-f]{16}\z/

    assert [message] =
             for(
               %{type: :status, data: %{message: "Ignored Cursor environment variables" <> _ = m}} <-
                 events,
               do: m
             )

    assert message == "Ignored Cursor environment variables: AGENT_CLI_FOO, CURSOR_CONFIG_DIR"
    refute message =~ "agent-key"
  end

  test "names to drop" do
    env = %{
      "CURSOR_API_KEY" => "k",
      "CURSOR_API_ENDPOINT" => "e",
      "CURSOR_X" => "1",
      "AGENT_CLI_Y" => "2",
      "PATH" => "/bin"
    }

    {set, unset, dropped} = Home.environment(env, %{"CURSOR_X" => "1"}, "/h")
    assert unset == ["AGENT_CLI_Y", "CURSOR_X"]
    assert dropped == ["CURSOR_X"]
    assert {"HOME", "/h"} in set
  end

  defp collect(id, env, events) do
    receive do
      {:report, ^id, %Report.Events{events: batch}, _, _, _} ->
        env =
          for %{type: :text, data: %{text: line}} <- batch,
              [k, v] <- [String.split(line, "=", parts: 2)],
              into: env,
              do: {k, v}

        collect(id, env, events ++ batch)

      {:report, ^id, %Report.Finished{}, _, _, _} ->
        {env, events}

      {:report, ^id, _other, _, _, _} ->
        collect(id, env, events)
    after
      5_000 -> flunk("no finished report")
    end
  end
end
