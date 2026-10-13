defmodule HelmsmanMCP.ServerDesignToolsTest do
  # add-agent-conversation 4.2: tools/list shows the draft tools only to
  # design runs; others calling them get an error result (decision 7).
  # The anubis session processes are not children of the test process: the
  # sandbox runs in shared mode.
  use HelmsmanWeb.ConnCase, async: false

  import Helmsman.AgentDesignsFixtures
  import Helmsman.ApiTokensFixtures
  import Helmsman.RunLifecycleFixtures

  alias Helmsman.Runs
  alias HelmsmanWeb.MCPClient

  @design_tools ~w(get_design propose_agent withdraw_agent)

  setup do
    ctx = design_fixture()
    start_design!(ctx.alice_scope)
    {:ok, [spec]} = Runs.claim(dctx(ctx.helper), "http://localhost:4000")
    start!(ctx.helper, spec.run_id)
    Map.put(ctx, :design_token, spec.mcp.token)
  end

  defp tool_names(token, sid, headers \\ []),
    do: token |> list_tools(sid, headers) |> Enum.map(& &1["name"])

  defp list_tools(token, sid, headers \\ []) do
    body = %{jsonrpc: "2.0", id: 1, method: "tools/list", params: %{}}

    resp =
      Req.post!("http://localhost/mcp",
        plug: HelmsmanWeb.Endpoint,
        headers:
          [
            {"accept", "application/json"},
            {"content-type", "application/json"},
            {"mcp-protocol-version", "2025-06-18"},
            {"authorization", "Bearer " <> token},
            {"mcp-session-id", sid}
          ] ++ headers,
        body: Jason.encode!(body),
        decode_body: false,
        retry: false
      )

    200 = resp.status
    Jason.decode!(resp.body)["result"]["tools"]
  end

  test "a design run's token lists the three draft tools and can call them", ctx do
    sid = MCPClient.handshake(ctx.design_token)
    names = tool_names(ctx.design_token, sid)

    assert Enum.all?(@design_tools, &(&1 in names))
    assert "list_projects" in names

    assert {:ok, %{"draft_version" => 0, "kind" => "agent"}} =
             MCPClient.call_tool(ctx.design_token, sid, "get_design")
  end

  test "propose_agent advertises null for the fields with a default, and null restores it " <>
         "over /mcp",
       ctx do
    account =
      Helmsman.ProviderAccountsFixtures.provider_account_fixture(ctx.alice, %{name: "zai"})

    sid = MCPClient.handshake(ctx.design_token)

    %{"inputSchema" => schema} =
      ctx.design_token |> list_tools(sid) |> Enum.find(&(&1["name"] == "propose_agent"))

    nullable =
      ~w(description runtime_id provider_account_id model effort capabilities access
         max_concurrency timeout_minutes idle_timeout_minutes)

    for field <- nullable do
      assert %{"oneOf" => types, "description" => _} = schema["properties"][field], field
      assert %{"type" => "null"} in types, field
    end

    assert schema["required"] == ["name"]
    assert schema["properties"]["name"]["type"] == "string"

    set = %{
      name: "fe-dev",
      provider: "claude",
      instructions: "x",
      runtime_id: ctx.runtime.id,
      provider_account_id: account.id,
      model: "glm-5.3",
      effort: "high",
      access: "workspace",
      max_concurrency: 5,
      capabilities: ["create_tasks"]
    }

    assert {:ok, _} = MCPClient.call_tool(ctx.design_token, sid, "propose_agent", set)

    reset =
      Map.new(
        ~w(runtime_id provider_account_id model effort access max_concurrency capabilities)a,
        &{&1, nil}
      )

    assert {:ok, %{"agent" => agent}} =
             MCPClient.call_tool(
               ctx.design_token,
               sid,
               "propose_agent",
               Map.put(reset, :name, "fe-dev")
             )

    assert %{
             "runtime_id" => nil,
             "provider_account_id" => nil,
             "model" => nil,
             "effort" => nil,
             "access" => "owner_only",
             "max_concurrency" => 2,
             "capabilities" => [],
             "instructions" => "x"
           } = agent

    # The advertised types are enforced before the tool runs.
    resp =
      MCPClient.rpc(ctx.design_token, sid, "tools/call", %{
        name: "propose_agent",
        arguments: %{name: "fe-dev", max_concurrency: "many"}
      })

    assert %{"error" => %{"code" => -32_602, "data" => %{"message" => message}}} =
             Jason.decode!(resp.body)

    assert message =~ "max_concurrency"
  end

  test "a task run's token and an hm_ token: not listed; a call is an error result", ctx do
    run = running_run!(ctx.helper, %{capabilities: ["read", "write_task"]})
    {_scope, run_token} = Helmsman.RunsFixtures.run_scope_fixture(run)
    %{token: api_token} = api_token_fixture(ctx.alice_scope)

    for token <- [run_token, api_token] do
      sid = MCPClient.handshake(token)
      names = tool_names(token, sid)
      assert names != [] and Enum.all?(@design_tools, &(&1 not in names))

      # A header sent by the client is replaced by the server's own.
      names = tool_names(token, sid, [{"x-helmsman-rpc-method", "tools/call"}])
      assert Enum.all?(@design_tools, &(&1 not in names))

      for tool <- @design_tools do
        assert MCPClient.call_tool(token, sid, tool, %{name: "x"}) ==
                 {:error, "#{tool} is only available in agent design runs."}
      end
    end
  end
end
