defmodule Helmsman.AgentDesigns.ConfirmTest do
  # add-agent-conversation 3.5: confirming the draft (decision 12).
  use Helmsman.DataCase, async: true

  import Helmsman.AgentDesignsFixtures
  import Helmsman.AgentsFixtures
  import Helmsman.RunsFixtures

  alias Helmsman.Actors.Actor
  alias Helmsman.{AgentDesigns, Agents, Events}
  alias Helmsman.Agents.AgentProfile
  alias Helmsman.Workspaces.Membership

  setup do
    ctx = design_fixture()
    %{id: id} = start_design!(ctx.alice_scope)
    end_and_settle!(run_turn!(ctx, id), :succeeded, summary: "ok")
    Map.put(ctx, :id, id)
  end

  defp version(id), do: design!(id).draft_version

  defp put!(ctx, name, extra \\ %{}) do
    attrs =
      Map.merge(
        %{
          name: name,
          provider: "claude",
          runtime_id: ctx.runtime.id,
          model: "sonnet",
          effort: "high",
          instructions: "You are #{name}.",
          description: "the #{name}"
        },
        extra
      )

    {:ok, _} = AgentDesigns.put_agent(ctx.alice_scope, ctx.id, version(ctx.id), attrs)
  end

  defp confirm(ctx, scope \\ nil),
    do: AgentDesigns.confirm(scope || ctx.alice_scope, ctx.id, version(ctx.id))

  defp agent_count, do: Repo.aggregate(Actor, :count)

  test "two agents created, owned by alice, as drafted (scenario)", ctx do
    put!(ctx, "fe-dev", %{access: "workspace", capabilities: ["create_tasks"]})
    put!(ctx, "pr-reviewer", %{model: "opus", max_concurrency: 1})
    Events.subscribe(Events.topic(:workspace, ctx.workspace.id))

    assert {:ok, %{design: design, agents: [fe, reviewer]}} = confirm(ctx)
    assert_receive {:agents_changed}

    assert design.status == :confirmed
    assert design.created_agents == [%{name: "fe-dev"}, %{name: "pr-reviewer"}]
    assert design!(ctx.id).created_actor_ids == [fe.actor_id, reviewer.actor_id]

    for {view, name} <- [{fe, "fe-dev"}, {reviewer, "pr-reviewer"}] do
      actor = Repo.get!(Actor, view.actor_id)
      profile = Repo.get_by!(AgentProfile, actor_id: actor.id)
      assert actor.name == name and actor.owner_id == ctx.alice.id
      assert profile.env in [nil, %{}] and profile.extra_mcp_servers in [nil, %{}]
      assert profile.custom_args == [] and profile.access_member_ids == []
      assert profile.runtime_id == ctx.runtime.id
      assert profile.description == "the #{name}"
    end

    assert %{access: "workspace", capabilities: ["create_tasks"], model: "sonnet"} = fe
    assert %{model: "opus", max_concurrency: 1, access: "owner_only"} = reviewer

    assert AgentDesigns.confirm(ctx.alice_scope, ctx.id, version(ctx.id)) ==
             {:error, :design_closed}
  end

  test "a name taken before confirming: none created, the name error (scenario)", ctx do
    put!(ctx, "fe-dev")
    put!(ctx, "pr-reviewer")
    {_bob, bob_scope} = member_scope_fixture(ctx.workspace)
    managed_agent_fixture(bob_scope, %{name: "pr-reviewer"})
    count = agent_count()
    Events.subscribe(Events.topic(:workspace, ctx.workspace.id))

    assert {:error, {:invalid, errors}} = confirm(ctx)
    assert Map.keys(errors) == ["pr-reviewer"]
    assert {"has already been taken", _} = errors["pr-reviewer"].errors[:name]
    assert agent_count() == count
    assert design!(ctx.id).status == :open
    refute_receive {:agents_changed}
  end

  test "every invalid agent's errors at once", ctx do
    put!(ctx, "fe-dev")
    put!(ctx, "qa")
    {_bob, bob_scope} = member_scope_fixture(ctx.workspace)
    managed_agent_fixture(bob_scope, %{name: "fe-dev"})
    managed_agent_fixture(bob_scope, %{name: "qa"})

    assert {:error, {:invalid, errors}} = confirm(ctx)
    assert errors |> Map.keys() |> Enum.sort() == ["fe-dev", "qa"]
  end

  test "a running turn, an empty draft, an old version (scenario)", ctx do
    assert confirm(ctx) == {:error, :empty_draft}
    put!(ctx, "fe-dev")

    assert AgentDesigns.confirm(ctx.alice_scope, ctx.id, version(ctx.id) - 1) ==
             {:error, :stale}

    {:ok, _} = AgentDesigns.send(ctx.alice_scope, ctx.id, "more")
    run_turn!(ctx, ctx.id)
    assert confirm(ctx) == {:error, :turn_running}
    assert Agents.get(ctx.alice_scope, "fe-dev") == {:error, :not_found}
  end

  test "a demoted user, the helper's run token and the owner cannot confirm (scenario)", ctx do
    put!(ctx, "fe-dev")
    {:ok, _} = AgentDesigns.send(ctx.alice_scope, ctx.id, "more")
    {run_scope, _token} = design_run_scope!(ctx, ctx.id)
    assert confirm(ctx, run_scope) == {:error, :forbidden}
    end_and_settle!(current_run!(ctx.id), :succeeded, summary: "ok")

    {_owner, owner_scope} = member_scope_fixture(ctx.workspace, :owner)
    assert confirm(ctx, owner_scope) == {:error, :not_found}

    Repo.update_all(
      from(m in Membership,
        where: m.workspace_id == ^ctx.workspace.id and m.user_id == ^ctx.alice.id
      ),
      set: [role: :viewer]
    )

    assert confirm(ctx) == {:error, :forbidden}
    assert Agents.get(ctx.alice_scope, "fe-dev") == {:error, :not_found}
  end
end
