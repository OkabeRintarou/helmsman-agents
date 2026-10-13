defmodule HelmsmanMCP.Tools.ProposeSquadTest do
  # add-squads 5.2: propose_squad, withdraw_agent and propose_agent around
  # the squad part, get_design of a squad conversation (agent-design "草稿
  # 工具"; decision 12), with the run token of a real design run.
  use Helmsman.DataCase, async: true

  import Helmsman.AgentDesignsFixtures
  import Helmsman.RunLifecycleFixtures
  import Helmsman.RunsFixtures

  alias Helmsman.Runs
  alias Helmsman.Runs.RunTokens
  alias HelmsmanMCP.Pipeline

  defp claim_turn(ctx) do
    {:ok, [spec]} = Runs.claim(dctx(ctx.helper), "http://localhost:4000")
    start!(ctx.helper, spec.run_id)
    {:ok, scope} = RunTokens.scope(spec.mcp.token)
    scope
  end

  defp call(scope, tool, args) do
    case Pipeline.call_tool(tool, args, scope, nil) do
      {:ok, json} -> {:ok, Jason.decode!(json)}
      error -> error
    end
  end

  defp agent(scope, name, extra \\ %{}) do
    ctx = Process.get(:ctx)

    {:ok, _} =
      call(
        scope,
        "propose_agent",
        Map.merge(
          %{
            "name" => name,
            "provider" => "claude",
            "runtime_id" => ctx.runtime.id,
            "instructions" => "You are #{name}."
          },
          extra
        )
      )
  end

  describe "a squad conversation" do
    setup do
      ctx = design_fixture()
      {_bob, bob_scope} = member_scope_fixture(ctx.workspace)
      view = start_squad_design!(ctx)
      Process.put(:ctx, ctx)
      Map.merge(ctx, %{id: view.id, bob: bob_scope.actor.name, scope: claim_turn(ctx)})
    end

    test "proposing the squad", ctx do
      for {name, model} <- [{"fe-dev", "sonnet"}, {"pr-reviewer", "opus"}, {"qa", "fable"}],
          do: agent(ctx.scope, name, %{"model" => model})

      agent(ctx.scope, "web-lead")
      version = design!(ctx.id).draft_version

      assert {:ok, result} =
               call(ctx.scope, "propose_squad", %{
                 "name" => "web-team",
                 "leader" => "web-lead",
                 "members" => [
                   %{"name" => "fe-dev", "role_note" => "前端"},
                   %{"name" => "pr-reviewer", "role_note" => "评审"},
                   %{"name" => "qa", "role_note" => "测试"},
                   %{"name" => ctx.bob, "role_note" => "产品决定"}
                 ]
               })

      assert %{
               "squad" => %{"name" => "web-team", "leader" => "web-lead", "updated_by" => "ai"},
               "trigger_summary" => %{"able" => 1, "total" => 2},
               "draft_version" => v
             } = result

      assert v == version + 1
      assert length(result["squad"]["members"]) == 4
      assert [_ | _] = result["warnings"]
      refute Repo.get_by(Helmsman.Actors.Actor, workspace_id: ctx.workspace.id, name: "web-team")
    end

    test "a person as the leader: field errors, draft unchanged", ctx do
      version = design!(ctx.id).draft_version

      assert {:error, text} = call(ctx.scope, "propose_squad", %{"leader" => ctx.bob})
      assert text =~ "The squad was not changed in the draft."
      assert text =~ "leader: #{ctx.bob} is not a managed agent"
      assert design!(ctx.id).draft_version == version
    end

    test "withdrawing an agent the squad refers to", ctx do
      agent(ctx.scope, "qa")
      agent(ctx.scope, "web-lead")

      {:ok, _} =
        call(ctx.scope, "propose_squad", %{
          "leader" => "web-lead",
          "members" => [%{"name" => "qa"}]
        })

      assert call(ctx.scope, "withdraw_agent", %{"name" => "qa"}) ==
               {:error,
                "qa is the leader or a member of the draft's squad. Change the squad first " <>
                  "(propose_squad), then remove it."}
    end

    test "a rename follows in the squad", ctx do
      agent(ctx.scope, "web-lead")
      {:ok, _} = call(ctx.scope, "propose_squad", %{"leader" => "web-lead"})

      {:ok, _} =
        call(ctx.scope, "propose_agent", %{"previous_name" => "web-lead", "name" => "web-captain"})

      assert design!(ctx.id).draft["squad"]["leader"] == "web-captain"
    end

    test "get_design: the squad, its hint and the workspace's people", ctx do
      assert {:ok, %{"kind" => "squad", "draft" => %{"squad" => _}, "trigger_summary" => _} = d} =
               call(ctx.scope, "get_design", %{})

      names = Enum.map(d["options"]["people"], & &1["name"])
      assert ctx.bob in names
    end
  end

  test "an agent conversation: propose_squad is forbidden" do
    ctx = design_fixture()
    start_design!(ctx.alice_scope)
    scope = claim_turn(ctx)

    assert call(scope, "propose_squad", %{"name" => "x"}) ==
             {:error, "This is not a squad conversation: propose_squad is not available."}

    assert {:ok, %{"kind" => "agent"} = d} = call(scope, "get_design", %{})
    refute Map.has_key?(d, "trigger_summary")
  end
end

defmodule HelmsmanMCP.Tools.ProposeSquadListTest do
  # add-squads 5.2: tools/list shows propose_squad only to the design runs
  # of squad conversations. Shared sandbox (anubis sessions).
  use HelmsmanWeb.ConnCase, async: false

  import Helmsman.AgentDesignsFixtures
  import Helmsman.RunLifecycleFixtures

  alias Helmsman.Runs
  alias HelmsmanWeb.MCPClient

  defp names(token) do
    sid = MCPClient.handshake(token)
    resp = MCPClient.rpc(token, sid, "tools/list")
    Jason.decode!(resp.body)["result"]["tools"] |> Enum.map(& &1["name"])
  end

  defp token(ctx) do
    {:ok, [spec]} = Runs.claim(dctx(ctx.helper), "http://localhost:4000")
    start!(ctx.helper, spec.run_id)
    spec.mcp.token
  end

  test "squad conversation: listed; agent conversation: not listed" do
    ctx = design_fixture()
    start_squad_design!(ctx)
    assert "propose_squad" in names(token(ctx))

    other = design_fixture()
    start_design!(other.alice_scope)
    listed = names(token(other))
    refute "propose_squad" in listed
    assert "propose_agent" in listed
  end
end
