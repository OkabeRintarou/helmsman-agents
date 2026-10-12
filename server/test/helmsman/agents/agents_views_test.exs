defmodule Helmsman.Agents.AgentsViewsTest do
  use Helmsman.DataCase, async: true

  import Helmsman.AccountsFixtures
  import Helmsman.AgentsFixtures
  import Helmsman.RunsFixtures
  import Helmsman.WorkspacesFixtures

  alias Helmsman.{Agents, Policy, QueryCount}
  alias Helmsman.Daemons.Runtime

  describe "views" do
    setup do
      dispatch_fixture()
    end

    test "carry last_run_at, workspace_id and actor_id", ctx do
      managed_agent_fixture(ctx.alice_scope, %{name: "keel/idle", runtime_id: nil})
      at = DateTime.utc_now()
      run_fixture(ctx.agent, %{status: :succeeded, inserted_at: DateTime.add(at, -60)})
      latest = run_fixture(ctx.agent, %{status: :failed, inserted_at: at})
      run_fixture(ctx.agent, %{status: :queued, inserted_at: DateTime.add(at, -30)})

      {:ok, views} = Agents.list(ctx.alice_scope)
      by_name = Map.new(views, &{&1.name, &1})

      assert %{last_run_at: last_run_at, workspace_id: workspace_id, actor_id: actor_id} =
               by_name["keel/dev"]

      assert last_run_at == latest.inserted_at
      assert {workspace_id, actor_id} == {ctx.workspace.id, ctx.agent.id}
      assert %{last_run_at: nil, active_runs: 0, queued_runs: 0} = by_name["keel/idle"]
      assert %{queued_runs: 1, active_runs: 0} = by_name["keel/dev"]

      assert {:ok, %{last_run_at: ^last_run_at}} = Agents.get(ctx.alice_scope, "keel/dev")
    end

    test "the list makes as many queries for 20 agents as for 1", ctx do
      {{:ok, [one]}, few} = QueryCount.count(fn -> Agents.list(ctx.alice_scope) end)
      runtime = Repo.get!(Runtime, profile(ctx.agent).runtime_id)

      for n <- 1..19 do
        managed_agent_fixture(ctx.alice_scope, %{name: "bulk/#{n}", runtime_id: runtime.id})
        run_fixture(agent_actor(ctx.workspace, "bulk/#{n}"), %{status: :running})
      end

      {{:ok, many}, more} = QueryCount.count(fn -> Agents.list(ctx.alice_scope) end)

      assert few == more
      assert length(many) == 20

      assert one.runtime == %{
               id: runtime.id,
               daemon_name: "test-machine",
               provider: "claude",
               status: "online",
               disabled: false
             }

      for view <- many, view.name != "keel/dev" do
        assert %{active_runs: 1, owner: %{id: owner_id, name: owner_name}, runtime: runtime_view} =
                 view

        assert {owner_id, owner_name} == {ctx.alice.id, ctx.alice.display_name}
        assert runtime_view == one.runtime
        assert %DateTime{} = view.last_run_at
      end
    end
  end

  describe "permissions/2" do
    test "agree with Policy for every role and a run scope" do
      ws_owner = user_fixture()
      workspace = workspace_fixture(ws_owner)
      alice = user_fixture()
      member_fixture(workspace, alice, :member)
      alice_scope = workspace_scope_fixture(alice, workspace)
      managed_agent_fixture(alice_scope, %{name: "keel/dev"})
      actor = agent_actor(workspace, "keel/dev")
      {:ok, view} = Agents.get(alice_scope, "keel/dev")

      scopes =
        [
          owner: {workspace_scope_fixture(ws_owner, workspace), false, true},
          admin: {role_scope(workspace, :admin), false, true},
          member_self: {alice_scope, true, true},
          member_other: {role_scope(workspace, :member), false, false},
          viewer: {role_scope(workspace, :viewer), false, false},
          run: {run_scope(actor), false, false}
        ]

      for {label, {scope, configure, administer}} <- scopes do
        assert Agents.permissions(scope, view) == %{configure: configure, administer: administer},
               "#{label}"

        assert configure == (Policy.authorize(scope, :configure_agent, actor) == :ok)
        assert administer == (Policy.authorize(scope, :administer_agent, actor) == :ok)
      end
    end

    test "a view of another workspace's agent gets nothing" do
      alice = user_fixture()
      a_owner = user_fixture()
      b_owner = user_fixture()
      ws_a = workspace_fixture(a_owner)
      ws_b = workspace_fixture(b_owner)
      member_fixture(ws_a, alice, :viewer)
      member_fixture(ws_b, alice, :admin)
      a_scope = workspace_scope_fixture(alice, ws_a)
      b_scope = workspace_scope_fixture(alice, ws_b)

      managed_agent_fixture(workspace_scope_fixture(a_owner, ws_a), %{name: "keel/dev"})
      managed_agent_fixture(workspace_scope_fixture(b_owner, ws_b), %{name: "keel/dev"})
      {:ok, a_view} = Agents.get(workspace_scope_fixture(a_owner, ws_a), "keel/dev")
      {:ok, b_view} = Agents.get(workspace_scope_fixture(b_owner, ws_b), "keel/dev")
      a_actor = agent_actor(ws_a, "keel/dev")
      b_actor = agent_actor(ws_b, "keel/dev")

      cases = [
        {a_scope, a_view, a_actor, %{configure: false, administer: false}},
        {a_scope, b_view, b_actor, %{configure: false, administer: false}},
        {b_scope, a_view, a_actor, %{configure: false, administer: false}},
        {b_scope, b_view, b_actor, %{configure: false, administer: true}}
      ]

      for {scope, view, actor, expected} <- cases do
        assert Agents.permissions(scope, view) == expected

        assert expected == %{
                 configure: Policy.authorize(scope, :configure_agent, actor) == :ok,
                 administer: Policy.authorize(scope, :administer_agent, actor) == :ok
               }
      end
    end
  end

  defp role_scope(workspace, role) do
    user = user_fixture()
    member_fixture(workspace, user, role)
    workspace_scope_fixture(user, workspace)
  end

  defp run_scope(actor) do
    run = run_fixture(actor, %{status: :running})
    {scope, _token} = run_scope_fixture(run)
    scope
  end
end
