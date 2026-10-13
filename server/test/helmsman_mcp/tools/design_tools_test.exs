defmodule HelmsmanMCP.Tools.DesignToolsTest do
  # add-agent-conversation 4.1: get_design, propose_agent, withdraw_agent
  # with the run token of a real design run (decision 7). The in-flight
  # race is in test/helmsman/agent_designs/race_test.exs.
  use Helmsman.DataCase, async: true

  import Helmsman.AgentDesignsFixtures
  import Helmsman.AgentsFixtures
  import Helmsman.ProviderAccountsFixtures
  import Helmsman.RunLifecycleFixtures
  import Helmsman.RunsFixtures
  import HelmsmanMCP.ToolHelpers, only: [mcp_session: 2]

  alias Helmsman.Actors.Actor
  alias Helmsman.{AgentDesigns, Agents, Events, Runs}
  alias Helmsman.AgentDesigns.Draft
  alias Helmsman.Runs.RunTokens
  alias HelmsmanMCP.Pipeline

  setup do
    ctx = design_fixture()
    %{id: id} = start_design!(ctx.alice_scope, "Build a frontend developer")
    {:ok, [spec]} = Runs.claim(dctx(ctx.helper), "http://localhost:4000")
    start!(ctx.helper, spec.run_id)
    {:ok, scope} = RunTokens.scope(spec.mcp.token)
    Map.merge(ctx, %{id: id, scope: scope, token: spec.mcp.token})
  end

  defp run_call(ctx, tool, args) do
    case Pipeline.call_tool(tool, args, ctx.scope, nil) do
      {:ok, json} -> {:ok, Jason.decode!(json)}
      error -> error
    end
  end

  defp fe_dev(ctx, extra \\ %{}) do
    Map.merge(
      %{
        "name" => "fe-dev",
        "provider" => "claude",
        "runtime_id" => ctx.runtime.id,
        "model" => "sonnet",
        "effort" => "high",
        "instructions" => "You build the web UI…"
      },
      extra
    )
  end

  defp draft(ctx), do: design!(ctx.id).draft

  test "propose an agent: in the draft with the defaults, no identity (scenario)", ctx do
    Events.subscribe(AgentDesigns.topic(ctx.id))
    actors = Repo.aggregate(Actor, :count)

    assert {:ok, %{"agent" => agent, "draft_version" => 1, "warnings" => []}} =
             run_call(ctx, "propose_agent", fe_dev(ctx))

    assert %{"access" => "owner_only", "max_concurrency" => 2, "updated_by" => "ai"} = agent
    assert Draft.find(draft(ctx), "fe-dev")["model"] == "sonnet"
    assert_receive {:agent_design, _}
    assert Repo.aggregate(Actor, :count) == actors
    assert design!(ctx.id).pending_edits == []
  end

  test "change one field: the rest stays (scenario)", ctx do
    {:ok, _} = run_call(ctx, "propose_agent", fe_dev(ctx))
    assert {:ok, _} = run_call(ctx, "propose_agent", %{"name" => "fe-dev", "effort" => "medium"})

    assert %{"effort" => "medium", "instructions" => "You build the web UI…", "model" => "sonnet"} =
             Draft.find(draft(ctx), "fe-dev")
  end

  test "a taken name, another user's runtime, a model not in the list: field errors " <>
         "(scenarios)",
       ctx do
    {_bob, bob_scope} = member_scope_fixture(ctx.workspace)
    {daemon, _} = daemon_fixture(bob_scope.user, %{workspace_ids: [ctx.workspace.id]})
    bob_runtime = runtime_fixture(ctx.workspace, daemon)

    for name <- ["helper", ctx.alice_scope.actor.name] do
      assert {:error, text} = run_call(ctx, "propose_agent", fe_dev(ctx, %{"name" => name}))
      assert text =~ "#{name} was not changed in the draft"
      assert text =~ "name: has already been taken"
    end

    assert {:error, text} =
             run_call(ctx, "propose_agent", fe_dev(ctx, %{"runtime_id" => bob_runtime.id}))

    assert text =~ "runtime_id: must be an enabled runtime owned by this agent owner"

    assert {:error, text} = run_call(ctx, "propose_agent", fe_dev(ctx, %{"model" => "gpt-5"}))
    assert text =~ "model: is not supported by the runtime (supported: fable, opus, sonnet)"

    assert draft(ctx) == %{"agents" => []}
  end

  test "the ninth agent is refused (scenario)", ctx do
    for i <- 1..8,
        do: {:ok, _} = run_call(ctx, "propose_agent", fe_dev(ctx, %{"name" => "a#{i}"}))

    assert {:error, text} = run_call(ctx, "propose_agent", fe_dev(ctx, %{"name" => "a9"}))
    assert text =~ "The draft already has 8 agents"
    assert length(Draft.agents(draft(ctx))) == 8
  end

  test "an offline runtime is a warning", ctx do
    Repo.update_all(from(r in Helmsman.Daemons.Runtime, where: r.id == ^ctx.runtime.id),
      set: [status: "offline"]
    )

    assert {:ok, %{"warnings" => [warning]}} = run_call(ctx, "propose_agent", fe_dev(ctx))

    assert warning ==
             "runtime #{ctx.runtime.id} (alice-mbp) is offline; runs will queue until it is online"
  end

  test "withdraw_agent removes an agent; an unknown one is an error", ctx do
    {:ok, _} = run_call(ctx, "propose_agent", fe_dev(ctx))

    assert {:ok, %{"removed" => "fe-dev", "draft_version" => 2}} =
             run_call(ctx, "withdraw_agent", %{"name" => "FE-DEV"})

    assert draft(ctx) == %{"agents" => []}
    assert {:error, text} = run_call(ctx, "withdraw_agent", %{"name" => "qa"})
    assert text =~ "qa is not in the draft"
  end

  test "after the user stopped the turn: refused, the draft unchanged (scenario)", ctx do
    {:ok, _} = AgentDesigns.stop_turn(ctx.alice_scope, ctx.id)

    for {tool, args} <- [
          {"propose_agent", fe_dev(ctx)},
          {"withdraw_agent", %{"name" => "x"}},
          {"get_design", %{}}
        ] do
      assert {:error, text} = run_call(ctx, tool, args)
      assert text =~ "This design turn has ended"
    end

    assert draft(ctx) == %{"agents" => []}
  end

  test "a task run and an hm_ token cannot use them (scenario)", ctx do
    task_run = running_run!(ctx.helper, %{capabilities: ["read", "create_tasks"]})
    {task_scope, _token} = run_scope_fixture(task_run)
    session = mcp_session(ctx.alice, ctx.workspace)

    for {tool, args} <- [
          {"propose_agent", fe_dev(ctx)},
          {"withdraw_agent", %{"name" => "x"}},
          {"get_design", %{}}
        ] do
      assert {:error, text} = Pipeline.call_tool(tool, args, task_scope, nil)
      assert text == "#{tool} is only available in agent design runs."
      assert {:error, ^text} = HelmsmanMCP.ToolHelpers.call(session, tool, args)
    end

    assert draft(ctx) == %{"agents" => []}
  end

  test "get_design: this turn's edits and the options, never a secret", ctx do
    account = provider_account_fixture(ctx.alice, %{name: "zai", api_key: "sk-SENTINEL-KEY"})

    {:ok, _} =
      Agents.update(ctx.alice_scope, "helper", %{
        provider_account_id: account.id,
        env: %{"FOO" => "env-SENTINEL-VALUE"}
      })

    # A second turn, after the user edited the draft.
    {:ok, _} = run_call(ctx, "propose_agent", fe_dev(ctx))
    end_and_settle!(current_run!(ctx.id), :succeeded, summary: "ok")
    v = design!(ctx.id).draft_version

    {:ok, _} =
      AgentDesigns.put_agent(ctx.alice_scope, ctx.id, v, %{name: "fe-dev", model: "opus"})

    Events.subscribe(AgentDesigns.topic(ctx.id))
    {:ok, view} = AgentDesigns.send(ctx.alice_scope, ctx.id, "再看看")
    assert_receive {:agent_design, _} = notification
    {:ok, [spec]} = Runs.claim(dctx(ctx.helper), "http://localhost:4000")
    {:ok, scope} = RunTokens.scope(spec.mcp.token)
    ctx = %{ctx | scope: scope}

    assert {:ok, design} = run_call(ctx, "get_design", %{})
    assert design["user_edits"] == [%{"agent" => "fe-dev", "fields" => ["model"]}]
    assert design["user_edits_text"] == "fe-dev (model)"
    assert design["helper"] == "helper" and design["user"] == ctx.alice.display_name

    assert [%{"id" => _, "name" => "zai", "cli" => "claude"}] =
             design["options"]["provider_accounts"]

    assert [%{"daemon_name" => "alice-mbp"}] = design["options"]["runtimes"]
    assert Enum.any?(design["options"]["agents"], &(&1["name"] == "helper"))
    assert design["limits"]["max_agents"] == 8

    for value <- [inspect(design), inspect(view), inspect(notification)] do
      refute value =~ "SENTINEL"
      refute value =~ "api.z.ai"
      refute value =~ spec.mcp.token
    end
  end
end
