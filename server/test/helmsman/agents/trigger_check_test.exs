defmodule Helmsman.Agents.TriggerCheckTest do
  use Helmsman.DataCase, async: true
  import Helmsman.AccountsFixtures
  import Helmsman.WorkspacesFixtures
  import Helmsman.AgentsFixtures
  alias Helmsman.Actors.Actor
  alias Helmsman.{Agents, Repo}
  alias Helmsman.Agents.AgentProfile

  test "access matrix never lets role bypass access or inactive state" do
    owner = user_fixture()
    workspace = workspace_fixture(owner)
    scope = workspace_scope_fixture(owner, workspace)

    users =
      for role <- [:member, :member, :admin, :viewer] do
        user = user_fixture()
        member_fixture(workspace, user, role)
        user
      end

    [listed, other, admin, viewer] = users
    stranger = user_fixture()

    for access <- ["owner_only", "members", "workspace"] do
      agent = managed_agent_fixture(scope, %{access: access, access_member_ids: [listed.id]})
      actor = Repo.one!(from a in Actor, where: a.name == ^agent.name)

      for {user, allowed} <- [
            {owner, true},
            {listed, access in ["members", "workspace"]},
            {other, access == "workspace"},
            {admin, access == "workspace"},
            {viewer, false},
            {stranger, false}
          ] do
        expected = if allowed, do: :ok, else: {:error, :unauthorized}
        assert Agents.trigger_check(workspace.id, user.id, actor) == expected
        disabled = %{actor | disabled_at: DateTime.utc_now(:second)}
        assert Agents.trigger_check(workspace.id, user.id, disabled) == {:error, :agent_disabled}
      end

      profile = Repo.one!(from p in AgentProfile, where: p.actor_id == ^actor.id)
      Repo.update!(Ecto.Changeset.change(profile, archived_at: DateTime.utc_now(:second)))
      assert Agents.trigger_check(workspace.id, owner.id, actor) == {:error, :agent_archived}
    end

    external =
      Repo.insert!(
        Actor.create_changeset(
          %Actor{workspace_id: workspace.id, owner_id: owner.id, kind: :agent},
          %{name: "external"}
        )
      )

    assert Agents.trigger_check(workspace.id, owner.id, external) == {:error, :not_managed}
    agent = managed_agent_fixture(scope)
    actor = Repo.one!(from a in Actor, where: a.name == ^agent.name)

    Repo.delete_all(
      from m in Helmsman.Workspaces.Membership,
        where: m.user_id == ^owner.id and m.workspace_id == ^workspace.id
    )

    assert Agents.trigger_check(workspace.id, owner.id, actor) == {:error, :unauthorized}
  end
end
