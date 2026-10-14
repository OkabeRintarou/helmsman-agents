defmodule HelmsmanMCP.PipelineLogTest do
  # server-release "生产日志": one log line per MCP tool call, and no token
  # in the logs. Raises the global log level and runs MCP sessions in
  # their own processes (shared sandbox): not async.
  use HelmsmanWeb.ConnCase, async: false

  import ExUnit.CaptureLog
  import Helmsman.AccountsFixtures
  import Helmsman.ApiTokensFixtures
  import Helmsman.ProjectsFixtures
  import Helmsman.RunsFixtures
  import Helmsman.WorkspacesFixtures

  alias HelmsmanMCP.{Pipeline, Sessions}
  alias HelmsmanWeb.MCPClient
  alias LoggerJSON.Formatters.Basic

  # The JSON formatter as production configures it (config/runtime.exs).
  @metadata [
    :request_id,
    :workspace_id,
    :token_id,
    :api_actor,
    :run_id,
    :daemon_id,
    :mcp_tool,
    :actor,
    :duration_ms,
    :result
  ]

  setup do
    owner = user_fixture()
    workspace = workspace_fixture(owner)
    scope = workspace_scope_fixture(owner, workspace)
    project = project_fixture(scope)

    task =
      task_fixture(scope, project.key, %{
        title: "Confidential launch plan",
        description: "Body text that must stay out of logs"
      })

    agent = agent_fixture(workspace, owner, "scout/logs")

    %{token: token, api_token: api_token} =
      api_token_fixture(scope, %{scopes: ["mcp", "api:read"], default_agent_id: agent.id})

    %{
      owner: owner,
      workspace: workspace,
      task: task,
      agent: agent,
      token: token,
      api_token: api_token
    }
  end

  # Captures at debug level (the global level is raised meanwhile).
  defp capture_debug(opts \\ [], fun) do
    level = Logger.level()
    Logger.configure(level: :debug)

    try do
      capture_log([level: :debug] ++ opts, fun)
    after
      Logger.configure(level: level)
    end
  end

  defp capture_json(fun),
    do: capture_debug([formatter: Basic.new(metadata: @metadata)], fun)

  # Every line is a JSON object.
  defp json_lines(log) do
    log
    |> String.split("\n", trim: true)
    |> Enum.map(&Jason.decode!/1)
  end

  defp tool_lines(lines), do: Enum.filter(lines, &(&1["message"] =~ ~r/^mcp tool call/))

  describe "a tool call is logged on one line (scenario)" do
    test "get_task: tool, duration and ok, with the workspace and identity, without content",
         ctx do
      token_scope = token_scope_fixture(ctx.owner, ctx.workspace, :mcp, ctx.api_token)
      sid = "log-#{System.unique_integer([:positive])}"
      :ok = Sessions.register(sid, token_scope, self())

      log =
        capture_json(fn ->
          assert {:ok, _json} =
                   Pipeline.call_tool(
                     "get_task",
                     %{"task_id" => ctx.task.ident},
                     token_scope,
                     sid
                   )
        end)

      assert [line] = log |> json_lines() |> tool_lines()
      metadata = line["metadata"]
      assert metadata["mcp_tool"] == "get_task"
      assert metadata["result"] == "ok"
      assert is_integer(metadata["duration_ms"]) and metadata["duration_ms"] >= 0
      assert metadata["workspace_id"] == ctx.workspace.id
      assert metadata["actor"] == "scout/logs"
      refute Map.has_key?(metadata, "run_id")
      assert line["message"] =~ "get_task"
      assert line["message"] =~ "result=ok"

      # Not even in the debug lines (queries log their parameters, not rows).
      refute log =~ "Confidential launch plan"
      refute log =~ "must stay out of logs"
      refute inspect(line) =~ ctx.task.ident
    end

    test "a refused call is error; the arguments are not logged", ctx do
      token_scope = token_scope_fixture(ctx.owner, ctx.workspace, :mcp, ctx.api_token)

      log =
        capture_json(fn ->
          assert {:error, _text} =
                   Pipeline.call_tool("get_task", %{"task_id" => "nope-424242"}, token_scope, nil)
        end)

      assert [line] = log |> json_lines() |> tool_lines()
      assert line["metadata"]["result"] == "error"
      refute inspect(line) =~ "nope-424242"
    end

    test "the call emits [:helmsman, :mcp, :tool_call] with the tool and result only", ctx do
      token_scope = token_scope_fixture(ctx.owner, ctx.workspace, :mcp, ctx.api_token)
      ref = :telemetry_test.attach_event_handlers(self(), [[:helmsman, :mcp, :tool_call]])
      on_exit(fn -> :telemetry.detach(ref) end)

      capture_debug(fn ->
        Pipeline.call_tool("get_task", %{"task_id" => ctx.task.ident}, token_scope, nil)
      end)

      assert_receive {[:helmsman, :mcp, :tool_call], ^ref, %{duration: duration}, metadata}
      assert is_integer(duration)
      assert metadata == %{tool: "get_task", result: :ok}
    end

    test "text format: the line names the tool, result and duration", ctx do
      token_scope = token_scope_fixture(ctx.owner, ctx.workspace, :mcp, ctx.api_token)

      log =
        capture_debug(fn ->
          Pipeline.call_tool("get_task", %{"task_id" => ctx.task.ident}, token_scope, nil)
        end)

      assert log =~ ~r/mcp tool call tool=get_task result=ok duration_ms=\d+/
    end
  end

  describe "tokens never reach the logs (scenario)" do
    # Every 8-character window of the token's secret part.
    defp refute_token(log, token) do
      [_prefix, secret] = String.split(token, "_", parts: 2)
      refute log =~ token

      for i <- 0..(String.length(secret) - 8) do
        refute log =~ String.slice(secret, i, 8), "a part of the token is in the log"
      end
    end

    test "an hm_ token on REST and MCP, an hmr_ token on MCP", ctx do
      %{agent: agent} = dispatch_fixture()
      daemon = daemon_of(agent)

      run =
        run_fixture(agent, %{
          status: :running,
          daemon_id: daemon.id,
          claimed_at: DateTime.utc_now(),
          started_at: DateTime.utc_now()
        })

      {_scope, run_token} = run_scope_fixture(run)

      for capture <- [&capture_json/1, &capture_debug/1] do
        log =
          capture.(fn ->
            # REST: the bearer header, and a token in the query string.
            conn =
              build_conn()
              |> put_req_header("authorization", "Bearer " <> ctx.token)
              |> get("/api/v1/tasks?token=#{ctx.token}&access_token=#{run_token}")

            assert conn.status == 404

            sid = MCPClient.handshake(ctx.token)

            assert {:ok, _} =
                     MCPClient.call_tool(ctx.token, sid, "get_task", %{task_id: ctx.task.ident})

            run_sid = MCPClient.handshake(run_token)
            assert {:ok, _} = MCPClient.call_tool(run_token, run_sid, "whoami")
          end)

        assert log =~ "mcp tool call"
        refute_token(log, ctx.token)
        refute_token(log, run_token)
      end
    end
  end
end
