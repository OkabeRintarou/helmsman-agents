defmodule HelmsmanDaemon.Adapters.CodexMCPUserTest do
  use HelmsmanDaemon.Case
  import ExUnit.CaptureLog
  @moduletag :tmp_dir
  alias HelmsmanDaemon.Adapters.Codex
  alias HelmsmanDaemon.Adapters.Codex.Config

  setup %{tmp_dir: dir} do
    HelmsmanDaemon.CodexLogin.install(dir)
    :ok
  end

  test "user servers are disabled on start and resume without copying values", %{tmp_dir: dir} do
    File.write!(
      Path.join(Config.home(), "config.toml"),
      ~s([mcp_servers.docs]\ncommand="USER_COMMAND_SENTINEL"\n[mcp_servers.remote]\nurl="USER_URL_SENTINEL"\nhttp_headers={x="USER_HEADER_SENTINEL"})
    )

    assert {:ok, _} = Codex.detect(fn _ -> {:ok, "codex-cli 0.162.1"} end)

    for resume <- [nil, "s-1"] do
      run = %{spec(1) | resume_session_id: resume}
      assert {:ok, launch} = Codex.prepare(run, dir, dir)
      text = IO.iodata_to_binary(launch.stdin)
      frame = text |> String.split("\n", trim: true) |> List.last() |> JSON.decode!()
      servers = frame["params"]["config"]["mcp_servers"]
      assert servers["docs"] == %{"enabled" => false}
      assert servers["remote"] == %{"enabled" => false}
      assert servers["helmsman"]["bearer_token_env_var"] == "HELMSMAN_RUN_TOKEN"
      refute inspect({launch.argv, text, launch.events}) =~ "SENTINEL"
      refute MapSet.member?(Codex.init_state(run).allowed_servers, "docs")
    end
  end

  test "colliding extra server is dropped and disabled", %{tmp_dir: dir} do
    File.write!(
      Path.join(Config.home(), "config.toml"),
      ~s([mcp_servers.docs]\nurl="USER_URL_SENTINEL")
    )

    run = spec(1)

    run = %{
      run
      | agent: %{
          run.agent
          | custom_args: [],
            extra_mcp_servers: %{
              "DOCS" => %{"url" => "EXTRA_URL_SENTINEL"},
              "safe" => %{"url" => "http://localhost/safe"}
            }
        }
    }

    assert {:ok, launch} = Codex.prepare(run, dir, dir)
    text = IO.iodata_to_binary(launch.stdin)
    assert text =~ "safe"
    refute text =~ "SENTINEL"
    assert [{:status, %{message: message}}] = launch.events
    assert message =~ "DOCS"
    refute message =~ "SENTINEL"
    refute MapSet.member?(Codex.init_state(run).allowed_servers, "docs")
  end

  test "runtime guard stops a disabled user server even when extra config had the same name" do
    File.write!(
      Path.join(Config.home(), "config.toml"),
      ~s([mcp_servers.docs]\ncommand="SECRET_SENTINEL")
    )

    run = spec(1)
    run = %{run | agent: %{run.agent | extra_mcp_servers: %{"docs" => %{"command" => "other"}}}}
    state = Codex.init_state(run)

    frame =
      JSON.encode!(%{
        "method" => "mcpServer/startupStatus/updated",
        "params" => %{"name" => "docs", "status" => "starting"}
      })

    {events, actions, state} = Codex.handle_output(:stdout, frame, state)
    assert actions != []
    assert {:failed, :cli_error, message} = elem(Codex.finish(0, state), 0)
    assert message =~ "docs"
    refute inspect(events) =~ "SECRET_SENTINEL"
  end

  test "helmsman case collision and legacy profile fail before launch", %{tmp_dir: dir} do
    for text <- [
          ~s([mcp_servers.HelmsMan]\nurl="SECRET_SENTINEL"),
          ~s(profile="SECRET_SENTINEL"\n[profiles.work]\nmodel_provider="ollama")
        ] do
      File.write!(Path.join(Config.home(), "config.toml"), text)
      assert {:error, message} = Codex.detect(fn _ -> {:ok, "codex-cli 0.162.1"} end)
      refute message =~ "SECRET_SENTINEL"
      assert {:error, {:workspace_prepare, ^message}} = Codex.prepare(spec(1), dir, dir)
    end
  end

  test "references resolve before Codex conversion with safe missing warnings", %{tmp_dir: dir} do
    run = spec(20)

    run = %{
      run
      | agent: %{
          run.agent
          | custom_args: [],
            extra_mcp_servers: %{
              "good" => %{
                "type" => "http",
                "url" => "https://a.test",
                "headers" => %{"Authorization" => "Bearer ${env:CANARY}"}
              },
              "missing" => %{"command" => "${env:NOT_SET}"}
            }
        }
    }

    {result, log} =
      with_log(fn -> Codex.prepare(run, dir, dir, %{"CANARY" => "CANARY_CODEX_VALUE"}) end)

    assert {:ok, launch} = result
    refute log =~ "CANARY_CODEX_VALUE"

    frames =
      IO.iodata_to_binary(launch.stdin)
      |> String.split("\n", trim: true)
      |> Enum.map(&JSON.decode!/1)

    frame = List.last(frames)
    config = frame["params"]["config"]["mcp_servers"]
    assert config["good"]["http_headers"]["Authorization"] == "Bearer CANARY_CODEX_VALUE"
    refute Map.has_key?(config, "missing")
    assert [{:status, %{level: :warning, message: message}}] = launch.events
    assert message =~ "NOT_SET"
    refute inspect(launch.events) =~ "CANARY_CODEX_VALUE"
  end
end
