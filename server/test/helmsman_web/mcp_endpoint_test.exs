defmodule HelmsmanWeb.MCPEndpointTest do
  # The anubis session processes and their tool tasks are not children of
  # the test process: the sandbox runs in shared mode.
  use HelmsmanWeb.ConnCase, async: false

  import Ecto.Query
  import Helmsman.AccountsFixtures
  import Helmsman.ApiTokensFixtures
  import Helmsman.WorkspacesFixtures

  alias Anubis.Server.Registry
  alias Helmsman.ApiTokens.ApiToken
  alias Helmsman.Presence
  alias Helmsman.Repo
  alias Helmsman.Workspaces.Membership
  alias HelmsmanMCP.Sessions

  @version "2025-06-18"

  setup do
    owner = user_fixture()
    workspace = workspace_fixture(owner)
    alice = user_fixture()
    member_fixture(workspace, alice, :member)
    bob = user_fixture()
    member_fixture(workspace, bob, :member)

    alice_scope = workspace_scope_fixture(alice, workspace)
    %{token: token, api_token: api_token} = api_token_fixture(alice_scope, %{scopes: ["mcp"]})
    %{token: bob_token} = api_token_fixture(workspace_scope_fixture(bob, workspace))

    on_exit(&kill_sessions/0)

    %{
      workspace: workspace,
      owner: owner,
      alice: alice,
      token: token,
      api_token: api_token,
      bob_token: bob_token,
      alice_scope: alice_scope
    }
  end

  defp kill_sessions do
    for sid <- Process.get(:sessions, []), {:ok, pid} <- [session_pid(sid)] do
      Process.exit(pid, :kill)
    end
  end

  defp session_pid(sid) do
    registry_mod = Anubis.Server.Supervisor.get_session_config(HelmsmanMCP.Server).registry_mod
    registry_mod.lookup_session(Registry.registry_name(HelmsmanMCP.Server), sid)
  end

  ## Requests

  defp mcp(token, method, body, opts \\ []) do
    conn =
      build_conn()
      |> put_req_header("accept", "application/json")
      |> put_req_header("content-type", "application/json")
      |> put_req_header("mcp-protocol-version", Keyword.get(opts, :version, @version))

    conn = if token, do: put_req_header(conn, "authorization", "Bearer " <> token), else: conn

    conn =
      case opts[:session] do
        nil -> conn
        sid -> put_req_header(conn, "mcp-session-id", sid)
      end

    case method do
      :post -> post(conn, "/mcp", Jason.encode!(body))
      :get -> conn |> put_req_header("accept", "text/event-stream") |> get("/mcp")
      :delete -> delete(conn, "/mcp")
    end
  end

  defp rpc(token, sid, method, params \\ %{}) do
    body = %{
      jsonrpc: "2.0",
      id: System.unique_integer([:positive]),
      method: method,
      params: params
    }

    mcp(token, :post, body, session: sid)
  end

  defp notify(token, sid, method) do
    mcp(token, :post, %{jsonrpc: "2.0", method: method}, session: sid)
  end

  defp initialize(token) do
    params = %{
      protocolVersion: @version,
      capabilities: %{},
      clientInfo: %{name: "test-client", version: "1.2.3"}
    }

    conn = rpc(token, nil, "initialize", params)
    assert conn.status == 200
    assert [sid] = get_resp_header(conn, "mcp-session-id")
    Process.put(:sessions, [sid | Process.get(:sessions, [])])
    {sid, Jason.decode!(conn.resp_body)["result"]}
  end

  defp handshake(token) do
    {sid, _result} = initialize(token)
    assert notify(token, sid, "notifications/initialized").status == 202
    sid
  end

  defp call_tool(token, sid, name, args) do
    conn = rpc(token, sid, "tools/call", %{name: name, arguments: args})
    assert conn.status == 200
    Jason.decode!(conn.resp_body)
  end

  defp tool_json(token, sid, name, args \\ %{}) do
    assert %{"result" => %{"content" => [%{"type" => "text", "text" => text}]} = result} =
             call_tool(token, sid, name, args)

    refute result["isError"]
    Jason.decode!(text)
  end

  defp topic(workspace), do: Presence.agents_topic(workspace.id)

  defp result!(conn) do
    assert conn.status == 200
    assert %{"result" => result} = Jason.decode!(conn.resp_body)
    result
  end

  # An mcp token of the workspace owner (an admin and above).
  defp owner_token(%{workspace: workspace, owner: owner}) do
    %{token: token} =
      api_token_fixture(workspace_scope_fixture(owner, workspace), %{scopes: ["mcp"]})

    token
  end

  ## Tests

  test "the whole handshake and the identity tools", %{token: token} = ctx do
    {sid, result} = initialize(token)

    assert result["protocolVersion"] == @version
    assert result["serverInfo"]["name"] == "helmsman"
    assert result["instructions"] =~ "identify"
    assert result["instructions"] =~ "helmsman://workflow"
    assert result["instructions"] =~ "work_on_task"
    assert %{"tools" => _, "resources" => _, "prompts" => _} = result["capabilities"]
    assert %{credential: credential, pid: pid} = Sessions.lookup(sid)
    assert credential == {:api_token, ctx.api_token.id}
    assert session_pid(sid) == {:ok, pid}

    assert notify(token, sid, "notifications/initialized").status == 202

    conn = rpc(token, sid, "tools/list")
    assert conn.status == 200
    tools = Jason.decode!(conn.resp_body)["result"]["tools"]
    assert length(tools) == 19

    assert Enum.map(tools, & &1["name"]) |> Enum.sort() ==
             Enum.sort(Enum.map(HelmsmanMCP.Tools.all(), & &1.name()))

    assert %{"actor" => nil, "source" => "none"} = tool_json(token, sid, "whoami")

    assert %{"name" => "keel/dev", "project" => "KEEL", "source" => "identify"} =
             tool_json(token, sid, "identify", %{name: "keel/dev", project: "KEEL"})

    assert %{"actor" => %{"name" => "keel/dev", "disabled" => false}, "source" => "identify"} =
             tool_json(token, sid, "whoami")

    actors = tool_json(token, sid, "list_actors")
    human = Helmsman.Actors.get_human(ctx.workspace.id, ctx.alice.id).name
    assert %{"owner" => ^human} = Enum.find(actors, &(&1["name"] == "keel/dev"))
  end

  @tag :capture_log
  test "the M4 flow: project, task, claim, question, resources and prompts",
       %{token: token} = ctx do
    owner_token = owner_token(ctx)
    owner_sid = handshake(owner_token)

    assert %{"key" => "DEMO", "archived" => false} =
             tool_json(owner_token, owner_sid, "create_project", %{key: "DEMO", name: "Demo"})

    sid = handshake(token)
    tool_json(token, sid, "identify", %{name: "demo/dev", project: "DEMO"})

    assert %{"id" => "DEMO-1", "status" => "NEW", "created_by" => %{"name" => "demo/dev"}} =
             tool_json(token, sid, "create_task", %{project_key: "DEMO", title: "Fix login"})

    assert %{"status" => "IN_PROGRESS", "assignee" => %{"name" => "demo/dev"}} =
             tool_json(token, sid, "transition_task", %{task_id: "DEMO-1", to: "in progress"})

    assert %{"id" => "DEMO-1#1", "kind" => "question"} =
             tool_json(token, sid, "add_feedback", %{
               task_id: "DEMO-1",
               content: "Minimum prefix length?",
               kind: "question"
             })

    assert [%{"id" => "DEMO-1", "open_question" => true}] =
             tool_json(token, sid, "list_my_tasks")

    # A domain error is a tool error with its text.
    assert %{"result" => %{"isError" => true, "content" => [%{"text" => text}]}} =
             call_tool(token, sid, "transition_task", %{task_id: "DEMO-1", to: "VERIFIED"})

    assert text ==
             "Cannot move DEMO-1 from IN_PROGRESS to VERIFIED. Allowed: DONE, REJECTED, CANCELLED."

    # Resources.
    assert %{"resources" => resources} = result!(rpc(token, sid, "resources/list"))

    assert Enum.map(resources, & &1["uri"]) |> Enum.sort() == [
             "helmsman://projects",
             "helmsman://workflow"
           ]

    assert %{"resourceTemplates" => [%{"uriTemplate" => "helmsman://tasks/{id}"}]} =
             result!(rpc(token, sid, "resources/templates/list"))

    assert %{"contents" => [%{"mimeType" => "text/markdown", "text" => markdown}]} =
             result!(rpc(token, sid, "resources/read", %{uri: "helmsman://tasks/demo-1"}))

    assert markdown =~ ~r/\A# DEMO-1: Fix login\n/
    assert markdown =~ "- Status: IN_PROGRESS"
    assert markdown =~ "Minimum prefix length?"

    assert %{"contents" => [%{"text" => workflow}]} =
             result!(rpc(token, sid, "resources/read", %{uri: "helmsman://workflow"}))

    assert workflow == HelmsmanMCP.Resources.workflow()

    assert %{"contents" => [%{"mimeType" => "application/json", "text" => projects}]} =
             result!(rpc(token, sid, "resources/read", %{uri: "helmsman://projects"}))

    assert Jason.decode!(projects) == tool_json(token, sid, "list_projects")

    conn = rpc(token, sid, "resources/read", %{uri: "helmsman://tasks/DEMO-9"})
    assert %{"error" => %{"code" => -32_002}} = Jason.decode!(conn.resp_body)

    # Prompts.
    assert %{"prompts" => [%{"name" => "work_on_task", "arguments" => [%{"name" => "task_id"}]}]} =
             result!(rpc(token, sid, "prompts/list"))

    assert %{
             "messages" => [
               %{"role" => "user", "content" => %{"type" => "text", "text" => prompt}}
             ]
           } =
             result!(
               rpc(token, sid, "prompts/get", %{
                 name: "work_on_task",
                 arguments: %{task_id: "DEMO-1"}
               })
             )

    assert prompt =~ "Fix login"
    assert prompt =~ ~s<transition_task(DEMO-1, "IN_PROGRESS")>

    conn =
      rpc(token, sid, "prompts/get", %{name: "work_on_task", arguments: %{task_id: "DEMO-9"}})

    assert %{"error" => %{"message" => _}} = Jason.decode!(conn.resp_body)
  end

  @tag :capture_log
  test "resources follow the token's workspace", %{token: token} do
    other_owner = user_fixture()
    other = workspace_fixture(other_owner)
    other_scope = workspace_scope_fixture(other_owner, other)
    Helmsman.ProjectsFixtures.project_fixture(other_scope, key: "OTHER")
    Helmsman.ProjectsFixtures.task_fixture(other_scope, "OTHER")

    sid = handshake(token)
    conn = rpc(token, sid, "resources/read", %{uri: "helmsman://tasks/OTHER-1"})
    assert %{"error" => %{"code" => -32_002}} = Jason.decode!(conn.resp_body)
  end

  @tag :capture_log
  test "tool argument errors are MCP errors; domain errors are tool errors", %{token: token} do
    sid = handshake(token)

    assert %{"error" => %{"code" => -32_602}} = call_tool(token, sid, "identify", %{})

    assert %{"result" => %{"isError" => true, "content" => [%{"text" => text}]}} =
             call_tool(token, sid, "identify", %{name: "Alice Smith"})

    assert text =~ "name: must be"
    refute text =~ "Error:"
  end

  test "clients that also accept SSE get the result as an event", %{token: token} do
    sid = handshake(token)

    body = %{
      jsonrpc: "2.0",
      id: 7,
      method: "tools/call",
      params: %{name: "whoami", arguments: %{}}
    }

    conn =
      build_conn()
      |> put_req_header("accept", "application/json, text/event-stream")
      |> put_req_header("content-type", "application/json")
      |> put_req_header("mcp-protocol-version", @version)
      |> put_req_header("authorization", "Bearer " <> token)
      |> put_req_header("mcp-session-id", sid)
      |> post("/mcp", Jason.encode!(body))

    assert conn.status == 200
    assert [_, data] = Regex.run(~r/^data: (.+)$/m, conn.resp_body)
    assert %{"id" => 7, "result" => %{"content" => [%{"text" => text}]}} = Jason.decode!(data)
    assert %{"source" => "none"} = Jason.decode!(text)
  end

  describe "authentication" do
    test "no token, a revoked token and a token without the mcp scope",
         %{token: token, api_token: api_token, alice_scope: alice_scope} do
      body = %{jsonrpc: "2.0", id: 1, method: "initialize", params: %{}}
      assert mcp(nil, :post, body).status == 401

      %{token: api_only} = api_token_fixture(alice_scope, %{scopes: ["api:read"]})
      assert mcp(api_only, :post, body).status == 403

      sid = handshake(token)

      Repo.update_all(from(t in ApiToken, where: t.id == ^api_token.id),
        set: [revoked_at: DateTime.utc_now(:second)]
      )

      assert rpc(token, sid, "tools/call", %{name: "whoami", arguments: %{}}).status == 401
    end

    test "another token with the session ID is 404", %{token: token, bob_token: bob_token} do
      sid = handshake(token)

      assert notify(bob_token, sid, "notifications/initialized").status == 404
      assert rpc(bob_token, sid, "tools/call", %{name: "whoami", arguments: %{}}).status == 404
      assert rpc(bob_token, sid, "tools/list").status == 404
      assert mcp(bob_token, :get, nil, session: sid).status == 404
      assert mcp(bob_token, :delete, nil, session: sid).status == 404

      params = %{protocolVersion: @version, capabilities: %{}, clientInfo: %{name: "x"}}
      assert rpc(bob_token, sid, "initialize", params).status == 404

      # The session is untouched.
      assert %{"source" => "none"} = tool_json(token, sid, "whoami")
    end

    test "a demoted user's identify is a tool error", %{token: token} = ctx do
      sid = handshake(token)

      Repo.update_all(
        from(m in Membership,
          where: m.workspace_id == ^ctx.workspace.id and m.user_id == ^ctx.alice.id
        ),
        set: [role: :viewer]
      )

      assert %{"result" => %{"isError" => true, "content" => [%{"text" => text}]}} =
               call_tool(token, sid, "identify", %{name: "keel/dev"})

      assert text =~ "(viewer)"
      assert %{actor_id: nil} = Sessions.lookup(sid)
    end
  end

  describe "a tool call queued behind another (review R1)" do
    # Holds the first tool call of the test in its task, before it runs.
    def hold_first_call(_event, _measurements, _metadata, parent) do
      if :ets.update_counter(parent.counter, :calls, 1) == 1 do
        send(parent.pid, {:held, self()})

        receive do
          :release -> :ok
        end
      end
    end

    setup do
      counter = :ets.new(:calls, [:public])
      :ets.insert(counter, {:calls, 0})
      id = {__MODULE__, make_ref()}

      :telemetry.attach(
        id,
        [:anubis_mcp, :server, :tool_call, :start],
        &__MODULE__.hold_first_call/4,
        %{pid: self(), counter: counter}
      )

      on_exit(fn -> :telemetry.detach(id) end)
    end

    defp async_call(token, sid, name, args \\ %{}) do
      Task.async(fn -> call_tool(token, sid, name, args) end)
    end

    defp text!(%{"result" => %{"content" => [%{"text" => text}]} = result}),
      do: {result["isError"], text}

    defp json!(response) do
      {false, text} = text!(response)
      Jason.decode!(text)
    end

    defp await_queued(sid, n) do
      {:ok, pid} = session_pid(sid)

      if :queue.len(:sys.get_state(pid).request_queue) >= n,
        do: :ok,
        else: await_queued(sid, n)
    end

    test "runs with its own request's role and workspace", %{token: token} = ctx do
      sid = handshake(token)

      first = async_call(token, sid, "whoami")
      assert_receive {:held, held}, 5_000

      Repo.update_all(
        from(m in Membership,
          where: m.workspace_id == ^ctx.workspace.id and m.user_id == ^ctx.alice.id
        ),
        set: [role: :viewer]
      )

      Repo.update_all(from(w in Helmsman.Workspaces.Workspace, where: w.id == ^ctx.workspace.id),
        set: [name: "Renamed"]
      )

      second = async_call(token, sid, "whoami")
      await_queued(sid, 1)
      send(held, :release)

      # The scope is read when the call runs: the held call too sees the change.
      assert %{"user" => %{"role" => "viewer"}} = json!(Task.await(first))

      assert %{"user" => %{"role" => "viewer"}, "workspace" => %{"name" => "Renamed"}} =
               json!(Task.await(second))

      # Serial requests after it see the same.
      assert %{"user" => %{"role" => "viewer"}} = tool_json(token, sid, "whoami")
    end

    test "a write queued after a demotion is refused under the lock", %{token: token} = ctx do
      sid = handshake(token)

      first = async_call(token, sid, "whoami")
      assert_receive {:held, held}, 5_000

      Repo.update_all(
        from(m in Membership,
          where: m.workspace_id == ^ctx.workspace.id and m.user_id == ^ctx.alice.id
        ),
        set: [role: :viewer]
      )

      second = async_call(token, sid, "identify", %{name: "keel/dev"})
      await_queued(sid, 1)
      send(held, :release)
      Task.await(first)

      assert {true, text} = text!(Task.await(second))
      assert text =~ "(viewer)"
      assert %{actor_id: nil} = Sessions.lookup(sid)
    end

    test "a token revoked while the call waits", %{token: token, api_token: api_token} do
      sid = handshake(token)

      first = async_call(token, sid, "whoami")
      assert_receive {:held, held}, 5_000
      second = async_call(token, sid, "whoami")
      await_queued(sid, 1)

      Repo.update_all(from(t in ApiToken, where: t.id == ^api_token.id),
        set: [revoked_at: DateTime.utc_now(:second)]
      )

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          send(held, :release)
          Task.await(first)
          assert {true, text} = text!(Task.await(second))
          assert text =~ "no longer valid"
          refute text =~ token
        end)

      refute log =~ token
    end
  end

  describe "session lifecycle" do
    test "DELETE ends the session", %{token: token} do
      sid = handshake(token)
      assert {:ok, pid} = session_pid(sid)
      ref = Process.monitor(pid)

      assert mcp(token, :delete, nil, session: sid).status == 200
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}
      _ = :sys.get_state(Sessions)

      assert Sessions.lookup(sid) == nil
      assert rpc(token, sid, "tools/list").status == 404
    end

    test "a killed session process is unregistered and goes offline", %{token: token} = ctx do
      Phoenix.PubSub.subscribe(Helmsman.PubSub, topic(ctx.workspace))
      sid = handshake(token)
      assert Map.has_key?(Presence.list(topic(ctx.workspace)), sid)
      assert_receive %{event: "presence_diff", payload: %{joins: %{^sid => _}}}

      assert {:ok, pid} = session_pid(sid)
      ref = Process.monitor(pid)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid, :killed}
      _ = :sys.get_state(Sessions)

      assert Sessions.lookup(sid) == nil
      assert_receive %{event: "presence_diff", payload: %{leaves: %{^sid => _}}}
      refute Map.has_key?(Presence.list(topic(ctx.workspace)), sid)
      assert rpc(token, sid, "tools/list").status == 404
    end

    test "a new session does not inherit the identity", %{token: token} do
      sid = handshake(token)
      tool_json(token, sid, "identify", %{name: "keel/dev"})
      assert mcp(token, :delete, nil, session: sid).status == 200

      sid2 = handshake(token)
      assert %{"source" => "none"} = tool_json(token, sid2, "whoami")
    end
  end

  @tag :capture_log
  test "a stateless request is refused", %{token: token} do
    body = %{jsonrpc: "2.0", id: 1, method: "tools/list", params: %{}}
    conn = mcp(token, :post, body, version: "2026-07-28")
    assert conn.status == 400
  end

  test "presence: initialize, identify and DELETE", %{token: token} = ctx do
    Phoenix.PubSub.subscribe(Helmsman.PubSub, topic(ctx.workspace))

    sid = handshake(token)
    assert_receive %{event: "presence_diff", payload: %{joins: %{^sid => %{metas: [meta]}}}}

    assert %{actor_name: nil, user_id: user_id, client: %{name: "test-client", version: "1.2.3"}} =
             meta

    assert user_id == ctx.alice.id

    tool_json(token, sid, "identify", %{name: "keel/dev"})

    assert_receive %{
      event: "presence_diff",
      payload: %{joins: %{^sid => %{metas: [%{actor_name: "keel/dev"}]}}}
    }

    assert mcp(token, :delete, nil, session: sid).status == 200
    assert_receive %{event: "presence_diff", payload: %{leaves: %{^sid => _}}}
    refute_receive %{event: "presence_diff"}
  end
end
