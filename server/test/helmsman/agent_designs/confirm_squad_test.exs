defmodule Helmsman.AgentDesigns.ConfirmSquadTest do
  # add-squads 5.3: confirming a squad conversation (agent-design "确认创
  # 建", decision 12).
  use Helmsman.DataCase, async: true

  import Helmsman.AgentDesignsFixtures
  import Helmsman.AgentsFixtures
  import Helmsman.RunsFixtures

  alias Helmsman.Actors.Actor
  alias Helmsman.{AgentDesigns, Agents, Squads}
  alias Helmsman.Agents.AgentProfile

  setup do
    ctx = design_fixture()
    {_carol, carol_scope} = member_scope_fixture(ctx.workspace)
    managed_agent_fixture(carol_scope, %{name: "carol/qa", access: "workspace"})
    managed_agent_fixture(carol_scope, %{name: "carol/lead", access: "workspace"})
    view = start_squad_design!(ctx)
    end_and_settle!(run_turn!(ctx, view.id), :succeeded, summary: "ok")
    Map.merge(ctx, %{id: view.id, carol_scope: carol_scope})
  end

  defp version(ctx), do: design!(ctx.id).draft_version

  defp put_agent!(ctx, name) do
    {:ok, _} =
      AgentDesigns.put_agent(ctx.alice_scope, ctx.id, version(ctx), %{
        name: name,
        provider: "claude",
        runtime_id: ctx.runtime.id,
        instructions: "You are #{name}."
      })
  end

  defp put_squad!(ctx, attrs),
    do: {:ok, _} = AgentDesigns.put_squad(ctx.alice_scope, ctx.id, version(ctx), attrs)

  defp confirm(ctx), do: AgentDesigns.confirm(ctx.alice_scope, ctx.id, version(ctx))

  defp squad_errors({:error, {:invalid, %{"squad" => cs}}}), do: Agents.errors(cs)

  defp actor(ctx, name), do: Repo.get_by(Actor, workspace_id: ctx.workspace.id, name: name)

  test "new agents and the squad in one confirmation; existing members unchanged", ctx do
    for name <- ~w(web-lead fe-dev pr-reviewer qa), do: put_agent!(ctx, name)
    carol_qa = actor(ctx, "carol/qa")
    carol_profile = Repo.get_by!(AgentProfile, actor_id: carol_qa.id)

    put_squad!(ctx, %{
      name: "web-team",
      leader: "web-lead",
      members: [
        %{name: "fe-dev", role_note: "前端"},
        %{name: "pr-reviewer", role_note: "评审"},
        %{name: "qa", role_note: "测试"},
        %{name: "carol/qa", role_note: "端到端"}
      ]
    })

    assert {:ok, %{design: design, agents: agents, squad: squad}} = confirm(ctx)
    assert design.status == :confirmed
    assert length(agents) == 4
    assert Enum.all?(agents, &(&1.owner.id == ctx.alice.id))

    assert %{name: "web-team", leader: %{name: "web-lead"}} = squad

    assert Enum.map(squad.members, &{&1.name, &1.role_note}) == [
             {"fe-dev", "前端"},
             {"pr-reviewer", "评审"},
             {"qa", "测试"},
             {"carol/qa", "端到端"}
           ]

    assert design!(ctx.id).created_actor_ids ==
             Enum.map(agents, & &1.actor_id) ++ [actor(ctx, "web-team").id]

    after_profile = Repo.get_by!(AgentProfile, actor_id: carol_qa.id)
    assert after_profile.updated_at == carol_profile.updated_at
  end

  test "only existing identities: no new agent, no empty_draft", ctx do
    managed_agent_fixture(ctx.alice_scope, %{name: "keel/lead"})
    managed_agent_fixture(ctx.alice_scope, %{name: "keel/fe"})
    put_squad!(ctx, %{name: "web-team", leader: "keel/lead", members: [%{name: "keel/fe"}]})

    assert {:ok, %{agents: [], squad: %{name: "web-team"}}} = confirm(ctx)
  end

  test "someone else's agent as the leader: nothing created", ctx do
    put_agent!(ctx, "fe-dev")
    put_squad!(ctx, %{name: "web-team", leader: "carol/lead", members: [%{name: "fe-dev"}]})

    # alice is the owner here: make her a member to test the rule.
    Repo.update_all(
      from(m in Helmsman.Workspaces.Membership,
        where: m.workspace_id == ^ctx.workspace.id and m.user_id == ^ctx.alice.id
      ),
      set: [role: :member]
    )

    assert %{leader: [_]} = squad_errors(confirm(ctx))
    refute actor(ctx, "fe-dev")
    refute actor(ctx, "web-team")
    assert design!(ctx.id).status == :open
  end

  test "the name taken before confirming: nothing created, the error on squad.name", ctx do
    put_agent!(ctx, "web-lead")
    put_squad!(ctx, %{name: "web-team", leader: "web-lead"})
    managed_agent_fixture(ctx.carol_scope, %{name: "web-team"})

    assert %{name: [_]} = squad_errors(confirm(ctx))
    refute actor(ctx, "web-lead")
    assert {:ok, []} = Squads.list(ctx.alice_scope)
    assert design!(ctx.id).status == :open
  end

  test "name or leader missing", ctx do
    assert %{name: [_], leader: [_]} = squad_errors(confirm(ctx))
  end
end
