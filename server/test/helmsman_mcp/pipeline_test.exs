defmodule HelmsmanMCP.PipelineTest do
  use Helmsman.DataCase, async: true

  import ExUnit.CaptureLog
  import Helmsman.AccountsFixtures
  import Helmsman.ApiTokensFixtures
  import Helmsman.WorkspacesFixtures

  alias Helmsman.Actors
  alias HelmsmanMCP.{Pipeline, Sessions}

  defmodule ReadTool do
    @moduledoc false
    use HelmsmanMCP.Tool, name: "test_read", description: "Read.", schema: %{}, mode: :read

    @impl HelmsmanMCP.Tool
    def call(args, ctx), do: {:ok, %{actor: ctx.scope.actor && ctx.scope.actor.name, args: args}}
  end

  defmodule WriteTool do
    @moduledoc false
    use HelmsmanMCP.Tool,
      name: "test_write",
      description: "Write.",
      schema: %{name: {:required, :string}},
      mode: :write

    # A real write: the agent `name`, created by the resolved writer's user.
    @impl HelmsmanMCP.Tool
    def call(%{"name" => name} = args, ctx) do
      with {:ok, created} <- Actors.identify(ctx.scope, %{name: name}) do
        {:ok, %{created: created.name, writer: ctx.scope.actor.name, args: args}}
      end
    end
  end

  defmodule CrashTool do
    @moduledoc false
    use HelmsmanMCP.Tool, name: "test_crash", description: "Crash.", schema: %{}, mode: :read

    @impl HelmsmanMCP.Tool
    def call(%{"how" => "raise"}, _ctx), do: raise("secret detail")
    def call(_args, _ctx), do: {:error, :mystery}
  end

  setup do
    owner = user_fixture()
    workspace = workspace_fixture(owner)
    alice = user_fixture()
    member_fixture(workspace, alice, :member)
    keel = agent_fixture(workspace, alice, "keel/dev")
    %{api_token: token} = api_token_fixture(workspace_scope_fixture(alice, workspace))
    scope = token_scope_fixture(alice, workspace, :mcp, token)
    session_id = "pipeline-#{System.unique_integer([:positive])}"
    :ok = Sessions.register(session_id, scope, self())

    %{scope: scope, keel: keel, sid: session_id, workspace: workspace, alice: alice}
  end

  defp call(module, args, scope, sid) do
    case Pipeline.call_module(module, args, scope, sid) do
      {:ok, json} -> {:ok, Jason.decode!(json)}
      {:error, text} -> {:error, text}
    end
  end

  defp with_default(scope, agent),
    do: %{scope | token: %{scope.token | default_agent_id: agent.id}}

  describe "read tools" do
    test "run as the session identity", %{scope: scope, keel: keel, sid: sid} do
      :ok = Sessions.put_identity(sid, keel.id, :identify)
      assert {:ok, %{"actor" => "keel/dev"}} = call(ReadTool, %{}, scope, sid)
    end

    test "run as the default agent, else as nobody", %{scope: scope, keel: keel, sid: sid} do
      assert {:ok, %{"actor" => "keel/dev"}} = call(ReadTool, %{}, with_default(scope, keel), sid)
      assert {:ok, %{"actor" => nil}} = call(ReadTool, %{a: 1}, scope, sid)
    end
  end

  describe "write tools" do
    test "the actor argument is resolved and removed", %{scope: scope, sid: sid} do
      assert {:ok, %{"writer" => "keel/dev", "created" => "w/1", "args" => args}} =
               call(WriteTool, %{"name" => "w/1", "actor" => "keel/dev"}, scope, sid)

      assert args == %{"name" => "w/1"}
      assert %{actor_id: nil, source: nil} = Sessions.lookup(sid)
    end

    test "as the session identity", %{scope: scope, keel: keel, sid: sid} do
      :ok = Sessions.put_identity(sid, keel.id, :identify)

      assert {:ok, %{"writer" => "keel/dev", "created" => "w/2"}} =
               call(WriteTool, %{name: "w/2"}, scope, sid)

      assert %{actor_id: id, source: :identify} = Sessions.lookup(sid)
      assert id == keel.id
    end

    test "as the default agent", %{scope: scope, keel: keel, sid: sid} do
      assert {:ok, %{"writer" => "keel/dev"}} =
               call(WriteTool, %{name: "w/3"}, with_default(scope, keel), sid)

      assert %{actor_id: nil, source: nil} = Sessions.lookup(sid)
    end

    test "the first write creates the session identity", %{scope: scope, sid: sid} = ctx do
      human = Actors.get_human(ctx.workspace.id, ctx.alice.id).name

      assert {:ok, %{"writer" => writer, "created" => "w/4"}} =
               call(WriteTool, %{name: "w/4"}, scope, sid)

      assert writer =~ ~r"^#{Regex.escape(human)}/session-[a-z0-9]{6}$"
      assert %{actor_id: id, source: :auto} = Sessions.lookup(sid)
      assert Actors.get(ctx.workspace.id, id).name == writer

      # Later writes use it.
      assert {:ok, %{"writer" => ^writer}} = call(WriteTool, %{name: "w/5"}, scope, sid)
    end

    test "a failed first write leaves no identity", %{scope: scope, sid: sid} do
      assert {:error, "name: " <> _} = call(WriteTool, %{name: "Bad Name"}, scope, sid)
      assert %{actor_id: nil, source: nil} = Sessions.lookup(sid)
    end
  end

  describe "unexpected failures" do
    test "an exception gives a reference that the log repeats", %{scope: scope, sid: sid} do
      log =
        capture_log(fn ->
          assert {:error, text} = call(CrashTool, %{how: "raise"}, scope, sid)
          send(self(), {:text, text})
        end)

      assert_received {:text, text}
      assert [_, ref] = Regex.run(~r/^Internal error \(ref ([0-9a-f]{8})\)\. /, text)
      refute text =~ "secret detail"
      assert log =~ "ref #{ref}"
      assert log =~ "secret detail"
      assert log =~ "test/helmsman_mcp/pipeline_test.exs"
    end

    test "an unknown error reason", %{scope: scope, sid: sid} do
      log =
        capture_log(fn ->
          assert {:error, text} = call(CrashTool, %{}, scope, sid)
          send(self(), {:text, text})
        end)

      assert_received {:text, text}
      assert [_, ref] = Regex.run(~r/\(ref ([0-9a-f]{8})\)/, text)
      assert log =~ "ref #{ref}" and log =~ ":mystery"
    end
  end

  test "call_tool/4 finds registered tools", %{scope: scope, sid: sid} do
    assert {:ok, json} = Pipeline.call_tool("whoami", %{}, scope, sid)
    assert %{"source" => "none"} = Jason.decode!(json)
    assert Pipeline.call_tool("nope", %{}, scope, sid) == {:error, "Unknown tool nope."}
  end
end
