defmodule HelmsmanDaemon.Adapters.CodexConfigRaceTest do
  use HelmsmanDaemon.Case
  @moduletag :tmp_dir
  alias HelmsmanDaemon.Adapters.Codex
  alias HelmsmanDaemon.Adapters.Codex.Config
  alias HelmsmanDaemon.{CodexLogin, Env}

  setup %{tmp_dir: dir} do
    cli = CodexLogin.install(dir, "barrier")
    Application.put_env(:helmsman_daemon, :codex_login_timeout_ms, 5_000)
    on_exit(fn -> File.write(cli <> ".release", "") end)
    {:ok, cli: cli}
  end

  for {name, text, expected} <- [
        {"reserved MCP", ~s([mcp_servers.helmsman]\nhttp_headers={Authorization="USER_SENTINEL"}),
         "MCP server named helmsman"},
        {"reserved MCP case variant", ~s([mcp_servers.HeLmSmAn]\ncommand="USER_SENTINEL"),
         "MCP server named helmsman"},
        {"reserved provider", ~s([model_providers.helmsman_account]\nname="USER_SENTINEL"),
         "model_providers.helmsman_account"},
        {"root markers", ~s(project_root_markers=["USER_SENTINEL"]), "project_root_markers"},
        {"legacy profile", ~s(profile="USER_SENTINEL"), "legacy profiles"},
        {"invalid TOML", "[USER_SENTINEL", "not valid TOML"},
        {"new MCP", ~s([mcp_servers.docs]\ncommand="USER_SENTINEL"), "changed during"},
        {"new provider", ~s(model_provider="USER_SENTINEL"), "changed during"}
      ] do
    test "rejects #{name} added during login before constructing a launch", %{
      tmp_dir: dir,
      cli: cli
    } do
      {task, path} = blocked_prepare(dir, cli)
      File.write!(path, unquote(text))
      File.write!(cli <> ".release", "")
      assert {:error, {:workspace_prepare, message}} = Task.await(task, 6_000)
      assert message =~ unquote(expected)
      refute message =~ "USER_SENTINEL"
      refute File.exists?(cli <> ".started")
      refute alive?(File.read!(cli <> ".pid"))
    end
  end

  test "rejects changed configuration even when the login probe fails or is unknown", %{
    tmp_dir: dir,
    cli: cli
  } do
    for result <- ["1", "2"] do
      File.rm(cli <> ".ready")
      File.rm(cli <> ".release")
      {task, path} = blocked_prepare(dir, cli, result)
      File.write!(path, ~s([mcp_servers.helmsman]\nhttp_headers={x="USER_SENTINEL"}))
      File.write!(cli <> ".release", "")
      assert {:error, {:workspace_prepare, message}} = Task.await(task, 6_000)
      assert message =~ "MCP server named helmsman"
      refute message =~ "USER_SENTINEL"
    end
  end

  test "configuration deletion changes a checked provider and is rejected", %{
    tmp_dir: dir,
    cli: cli
  } do
    {task, path} = blocked_prepare(dir, cli)
    File.rm!(path)
    File.write!(cli <> ".release", "")
    assert {:error, {:workspace_prepare, message}} = Task.await(task, 6_000)
    assert message =~ "changed during"
  end

  test "unchanged configuration uses the validated MCP snapshot for start and resume", %{
    tmp_dir: dir,
    cli: cli
  } do
    for resume <- [nil, "s-1"] do
      File.rm(cli <> ".ready")
      File.rm(cli <> ".release")
      {task, path} = blocked_prepare(dir, cli, "0", resume)
      File.write!(cli <> ".release", "")
      assert {:ok, launch} = Task.await(task, 6_000)
      request = launch.stdin |> List.last() |> JSON.decode!()
      assert request["params"]["config"]["mcp_servers"]["docs"] == %{"enabled" => false}
      assert request["method"] == if(resume, do: "thread/resume", else: "thread/start")
      refute inspect({launch.argv, launch.stdin, launch.events}) =~ "USER_SENTINEL"

      # Changing the file after prepare must not change the guard's allow list.
      File.write!(path, "")
      state = Codex.init_state(run(resume), launch)
      refute MapSet.member?(state.allowed_servers, "DOCS")
      assert MapSet.member?(state.allowed_servers, "safe")
      assert MapSet.member?(state.allowed_servers, "helmsman")

      frame =
        JSON.encode!(%{
          "method" => "mcpServer/startupStatus/updated",
          "params" => %{"name" => "DOCS", "status" => "starting"}
        })

      {_events, actions, state} = Codex.handle_output(:stdout, frame, state)
      assert actions != []
      assert {:failed, :cli_error, _} = elem(Codex.finish(0, state), 0)
    end
  end

  defp blocked_prepare(dir, cli, result \\ "0", resume \\ nil) do
    path = Path.join(Config.home(), "config.toml")
    File.write!(path, ~s(model_provider="openai"\n[mcp_servers.docs]\ncommand="USER_SENTINEL"))
    File.write!(cli <> ".result", result)
    task = Task.async(fn -> Codex.prepare(run(resume), dir, dir, Env.child()) end)
    eventually(fn -> File.exists?(cli <> ".ready") end)
    {task, path}
  end

  defp run(resume) do
    run = spec(1)

    %{
      run
      | resume_session_id: resume,
        agent: %{
          run.agent
          | custom_args: [],
            extra_mcp_servers: %{
              "DOCS" => %{"command" => "EXTRA_SENTINEL"},
              "safe" => %{"command" => "fake-safe"}
            }
        }
    }
  end
end
