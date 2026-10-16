defmodule Helmsman.AgentDesigns.EditExpireTest do
  # add-edit-design-conversations 1.6: agent-design 「修改对话的目标失效」
  # (decision 12).
  use Helmsman.DataCase, async: true

  import Helmsman.AgentDesignsFixtures
  import Helmsman.RunsFixtures

  alias Helmsman.Actors.Actor
  alias Helmsman.{AgentDesigns, Agents, Squads}
  alias Helmsman.Agents.AgentProfile
  alias Helmsman.Runs.Run
  alias Helmsman.Workspaces.Membership

  setup do
    edit_fixture()
  end

  defp last_message(id), do: List.last(messages!(id))

  test "the target archived: expired with a message, the turn stopped; a new one may start",
       ctx do
    %{id: id} = start_edit!(ctx.alice_scope, "fe-dev")
    run_id = design!(id).current_run_id
    {:ok, _} = Agents.archive(ctx.alice_scope, "fe-dev")

    assert %{expired: 1} = AgentDesigns.expire()
    d = design!(id)
    assert d.status == :expired and is_nil(d.current_run_id)
    assert %{role: :system, code: "target_archived"} = last_message(id)
    assert Repo.get!(Run, run_id).status in [:cancelled, :cancelling]

    assert {:ok, %{kind: :squad_edit}} =
             AgentDesigns.start_edit(ctx.alice_scope, %{
               target: "web-team",
               helper: "helper",
               message: "again"
             })
  end

  test "an admin demoted to member: expired, permission_lost", ctx do
    %{id: id} = start_edit!(ctx.carol_scope, "fe-dev")

    Repo.update_all(
      from(m in Membership,
        where: m.workspace_id == ^ctx.workspace.id and m.user_id == ^ctx.carol.id
      ),
      set: [role: :member]
    )

    assert %{expired: 1} = AgentDesigns.expire()
    assert design!(id).status == :expired
    assert %{code: "permission_lost"} = last_message(id)
  end

  test "a squad's leader changed away from the user's agent: permission_lost", ctx do
    Helmsman.AgentsFixtures.managed_agent_fixture(ctx.bob_scope, %{
      name: "bob-lead",
      runtime_id: nil,
      access: "workspace"
    })

    Helmsman.SquadsFixtures.squad_fixture(ctx.bob_scope, %{name: "bob-team", leader: "bob-lead"})
    %{id: id} = start_edit!(ctx.bob_scope, "bob-team")
    {:ok, _} = Squads.update(ctx.alice_scope, "bob-team", %{leader: "web-lead"})

    assert %{expired: 1} = AgentDesigns.expire()
    assert %{code: "permission_lost"} = last_message(id)
  end

  test "a disabled agent stays editable; nothing else expires", ctx do
    %{id: id} = start_edit!(ctx.alice_scope, "fe-dev")
    {:ok, _} = Agents.disable(ctx.alice_scope, "fe-dev")
    %{id: create} = start_design!(ctx.carol_scope)

    assert %{expired: 0} = AgentDesigns.expire()
    assert design!(id).status == :open
    assert design!(create).status == :open
  end

  test "a deleted target deletes its conversations", ctx do
    Helmsman.AgentsFixtures.managed_agent_fixture(ctx.alice_scope, %{
      name: "tmp-bot",
      runtime_id: ctx.runtime.id
    })

    %{id: id} = start_edit!(ctx.alice_scope, "tmp-bot")
    target = agent_actor(ctx.workspace, "tmp-bot")
    Repo.delete_all(from(p in AgentProfile, where: p.actor_id == ^target.id))
    Repo.delete_all(from(a in Actor, where: a.id == ^target.id))

    refute Repo.get(Helmsman.AgentDesigns.AgentDesign, id)
  end
end
