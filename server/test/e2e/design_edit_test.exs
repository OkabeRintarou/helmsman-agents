defmodule Helmsman.E2E.DesignEditTest do
  # add-edit-design-conversations 3.1: edit conversations end to end with
  # the daemon of `daemon/` and its fake CLI (decision 16). The fake CLI
  # cannot call MCP itself: at a `barrier` the test acts as the helper's
  # CLI with a fresh token of the design run and calls the draft tools
  # through the endpoint; the person confirms with the domain function the
  # page calls. Run with `mix test --only e2e test/e2e/design_edit_test.exs`.
  use ExUnit.Case, async: false

  @moduletag :e2e
  if :os.type() != {:unix, :linux} do
    @moduletag skip: "daemon E2E tests require Linux"
  end

  @moduletag timeout: 240_000

  import Ecto.Query
  import Helmsman.AccountsFixtures
  import Helmsman.AgentsFixtures
  import Helmsman.RunsFixtures
  import Helmsman.WorkspacesFixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias Helmsman.{AgentDesigns, Agents, CommittedData, DaemonE2E, Repo}
  alias Helmsman.AgentDesigns.AgentDesign
  alias Helmsman.Agents.AgentProfile
  alias Helmsman.Daemons.Runtime
  alias Helmsman.Runs.{Run, RunToken, RunTokens}
  alias HelmsmanWeb.MCPClient

  setup do
    :ok = Sandbox.mode(Repo, :auto)
    on_exit(fn -> Sandbox.mode(Repo, :manual) end)

    tag = Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
    home = Path.join(System.tmp_dir!(), "helmsman-e2e-design-edit-#{tag}")
    File.mkdir_p!(home)
    unless System.get_env("HELMSMAN_E2E_KEEP"), do: on_exit(fn -> File.rm_rf!(home) end)

    ctx =
      CommittedData.unboxed(fn ->
        alice = user_fixture(%{email: "design-edit-e2e-#{tag}@test.invalid"})
        carol = user_fixture(%{email: "design-edit-e2e-carol-#{tag}@test.invalid"})
        ws = workspace_fixture(alice, %{slug: "design-edit-#{tag}", name: "Design #{tag}"})
        member_fixture(ws, carol, :admin)
        {daemon, token} = daemon_fixture(alice, %{workspace_ids: [ws.id]})

        %{
          alice: alice,
          carol: carol,
          workspace: ws,
          alice_scope: workspace_scope_fixture(alice, ws),
          carol_scope: workspace_scope_fixture(carol, ws),
          daemon: daemon,
          token: token
        }
      end)

    on_exit(fn -> CommittedData.delete_user_data!([ctx.alice.id, ctx.carol.id]) end)
    Map.merge(ctx, %{tag: tag, home: home})
  end

  defp start(ctx) do
    url = DaemonE2E.start_endpoint()
    DaemonE2E.write_credentials(ctx.home, url, ctx.daemon.id, ctx.token)
    port = DaemonE2E.start_daemon(ctx.home)

    runtime =
      DaemonE2E.wait_until(port, "the runtime online", fn ->
        case Repo.get_by(Runtime, daemon_id: ctx.daemon.id, workspace_id: ctx.workspace.id) do
          %Runtime{status: "online"} = runtime -> runtime
          _ -> nil
        end
      end)

    {port, runtime}
  end

  # The helper's every turn: wait at the barrier (the test is its CLI
  # meanwhile), then reply.
  defp helper!(ctx, runtime, barrier) do
    path = Path.join(ctx.home, "helper")

    File.write!(path, """
    barrier #{barrier}
    json {"type":"result","data":{"text":"Changed the draft; please check and confirm.","success":true}}
    exit 0
    """)

    managed_agent_fixture(ctx.alice_scope, %{
      name: "helper",
      runtime_id: runtime.id,
      access: "workspace",
      custom_args: [path]
    })
  end

  # Two values of `field` the runtime accepts (any when it lists none; the
  # fake CLI's runtime reports one model: the CLI default, then that one).
  defp options(runtime, :model), do: pick(runtime.models, ["sonnet", "opus"])
  defp options(runtime, :effort), do: pick(runtime.efforts, ["high", "low"])

  defp pick([a, b | _], _fallback), do: [a, b]
  defp pick([a], _fallback), do: [nil, a]
  defp pick([], fallback), do: fallback

  # One turn of conversation `id`: the test acts as the CLI at the barrier
  # (`fun` gets the token and session), then the run ends and settles.
  defp turn(port, id, barrier, fun) do
    run =
      DaemonE2E.wait_until(port, "the design turn running", fn ->
        with %AgentDesign{current_run_id: run_id} when is_integer(run_id) <-
               Repo.get(AgentDesign, id),
             %Run{status: :running} = run <- Repo.get(Run, run_id),
             do: run,
             else: (_ -> nil)
      end)

    DaemonE2E.wait_until(port, "#{barrier} reached", fn -> File.exists?(barrier <> ".ready") end)

    token =
      CommittedData.unboxed(fn ->
        Repo.delete_all(from(t in RunToken, where: t.run_id == ^run.id))
        {:ok, token} = RunTokens.issue(Repo.get!(Run, run.id))
        token
      end)

    result = fun.(token, MCPClient.handshake(token))
    File.write!(barrier <> ".release", "")

    DaemonE2E.wait_until(port, "run #{run.id} ended", fn ->
      Repo.get!(Run, run.id).status in Run.ended_statuses()
    end)

    Oban.drain_queue(queue: :runs)

    DaemonE2E.wait_until(port, "the turn settled", fn ->
      is_nil(Repo.get!(AgentDesign, id).current_run_id)
    end)

    File.rm(barrier <> ".ready")
    File.rm(barrier <> ".release")
    result
  end

  defp profile_of(ctx, name), do: profile(agent_actor(ctx.workspace, name))

  defp version(id), do: Repo.get!(AgentDesign, id).draft_version

  test "edit an agent: the helper drafts through MCP, the owner confirms, a changed baseline is confirmed again, an admin cannot write execution fields",
       ctx do
    {port, runtime} = start(ctx)
    barrier = Path.join(ctx.home, "barrier")
    helper!(ctx, runtime, barrier)
    [model_a, model_b] = options(runtime, :model)
    [effort_a, effort_b] = options(runtime, :effort)

    managed_agent_fixture(ctx.alice_scope, %{
      name: "fe-dev",
      runtime_id: runtime.id,
      model: model_a,
      effort: effort_a,
      description: "Builds the web UI",
      instructions: "You build the web UI.",
      custom_args: ["--verbose"],
      env: %{"API_TOKEN" => "e2e-secret"}
    })

    before = profile_of(ctx, "fe-dev")

    # 1. alice edits fe-dev: the helper reads the draft and changes the model.
    {:ok, %{id: id, kind: :agent_edit}} =
      AgentDesigns.start_edit(ctx.alice_scope, %{
        target: "fe-dev",
        helper: "helper",
        message: "Switch fe-dev to #{model_b}"
      })

    turn(port, id, barrier, fn token, sid ->
      assert {:ok, design} = MCPClient.call_tool(token, sid, "get_design", %{})
      assert design["kind"] == "agent_edit"
      assert design["target"]["name"] == "fe-dev"
      assert design["changes"] == []
      refute Jason.encode!(design) =~ "e2e-secret"

      assert {:ok, %{"agent" => %{"model" => ^model_b}}} =
               MCPClient.call_tool(token, sid, "propose_agent", %{
                 "name" => "fe-dev",
                 "model" => model_b
               })

      assert {:error, text} =
               MCPClient.call_tool(token, sid, "withdraw_agent", %{"name" => "fe-dev"})

      assert text =~ "agent edit conversation"
    end)

    assert %{messages: messages} = view!(ctx.alice_scope, id)
    assert Enum.any?(messages, &(&1.role == :assistant))

    assert {:ok, %{agents: [%{name: "fe-dev"}]}} =
             AgentDesigns.confirm(ctx.alice_scope, id, version(id))

    after_ = profile_of(ctx, "fe-dev")
    assert after_.model == model_b
    assert after_.effort == before.effort
    assert after_.instructions == before.instructions
    assert after_.custom_args == before.custom_args
    assert after_.env == before.env

    # 2. A new conversation changes the effort; alice changes it on the
    # page meanwhile: the confirm rebaselines, then goes through.
    {:ok, %{id: id}} =
      AgentDesigns.start_edit(ctx.alice_scope, %{
        target: "fe-dev",
        helper: "helper",
        message: "Effort #{effort_b}"
      })

    turn(port, id, barrier, fn token, sid ->
      assert {:ok, _} =
               MCPClient.call_tool(token, sid, "propose_agent", %{
                 "name" => "fe-dev",
                 "effort" => effort_b
               })
    end)

    {:ok, _} =
      Agents.update(ctx.alice_scope, "fe-dev", %{effort: effort_a, max_concurrency: 4})

    assert {:error, {:baseline_changed, ["max_concurrency"]}} =
             AgentDesigns.confirm(ctx.alice_scope, id, version(id))

    assert profile_of(ctx, "fe-dev").effort == effort_a
    assert {:ok, _} = AgentDesigns.confirm(ctx.alice_scope, id, version(id))
    assert %AgentProfile{effort: ^effort_b, max_concurrency: 4} = profile_of(ctx, "fe-dev")

    # 3. carol (admin, not the owner): the helper cannot propose the
    # instructions; a model slipped into her draft is not written.
    {:ok, %{id: id}} =
      AgentDesigns.start_edit(ctx.carol_scope, %{
        target: "fe-dev",
        helper: "helper",
        message: "Lower the concurrency and change the instructions"
      })

    turn(port, id, barrier, fn token, sid ->
      assert {:error, text} =
               MCPClient.call_tool(token, sid, "propose_agent", %{
                 "name" => "fe-dev",
                 "instructions" => "New."
               })

      assert text =~ "only the owner"

      assert {:ok, design} = MCPClient.call_tool(token, sid, "get_design", %{})
      assert "instructions" in design["readonly"]

      assert {:ok, _} =
               MCPClient.call_tool(token, sid, "propose_agent", %{
                 "name" => "fe-dev",
                 "max_concurrency" => 1
               })
    end)

    CommittedData.unboxed(fn ->
      design = Repo.get!(AgentDesign, id)
      [entry] = design.draft["agents"]

      Repo.update_all(from(d in AgentDesign, where: d.id == ^id),
        set: [draft: %{"agents" => [Map.put(entry, "model", model_a)]}]
      )
    end)

    assert {:error, :forbidden} = AgentDesigns.confirm(ctx.carol_scope, id, version(id))
    assert profile_of(ctx, "fe-dev").model == model_b

    CommittedData.unboxed(fn ->
      design = Repo.get!(AgentDesign, id)
      [entry] = design.draft["agents"]

      Repo.update_all(from(d in AgentDesign, where: d.id == ^id),
        set: [draft: %{"agents" => [Map.put(entry, "model", model_b)]}]
      )
    end)

    assert {:ok, _} = AgentDesigns.confirm(ctx.carol_scope, id, version(id))
    assert %AgentProfile{max_concurrency: 1, model: ^model_b} = profile_of(ctx, "fe-dev")

    DaemonE2E.stop_daemon(port)
  end

  defp view!(scope, id) do
    {:ok, view} = AgentDesigns.get(scope, id)
    view
  end
end
