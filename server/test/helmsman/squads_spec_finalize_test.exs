defmodule Helmsman.SquadsSpecFinalizeTest do
  # add-spec-workflow 1.5: squads 「小队的规格定稿方式」 (decision 7).
  use Helmsman.DataCase, async: true

  import Helmsman.SquadsFixtures

  alias Helmsman.{Repo, Squads}
  alias Helmsman.Squads.Squad

  setup do
    # carol (member) leads carol-team with her own agent; dave is an admin.
    ctx = squads_fixture()
    squad_fixture(ctx.carol_scope, %{name: "carol-team"})
    {_dave, admin_scope} = Helmsman.RunsFixtures.member_scope_fixture(ctx.workspace, :admin)
    Map.put(ctx, :admin_scope, admin_scope)
  end

  defp mode(name) do
    Repo.one!(
      from(s in Squad,
        join: a in assoc(s, :actor),
        where: a.name == ^name,
        select: s.spec_finalize
      )
    )
  end

  test "reading a squad gives its mode, empty by default", ctx do
    assert {:ok, %{spec_finalize: nil}} = Squads.get(ctx.alice_scope, "web-team")
  end

  test "the member owning the leader tightens to approval", ctx do
    assert {:ok, _} = Squads.update(ctx.carol_scope, "carol-team", %{spec_finalize: "approval"})
    assert mode("carol-team") == :approval
    assert {:ok, _} = Squads.update(ctx.carol_scope, "carol-team", %{spec_finalize: nil})
    assert mode("carol-team") == nil
  end

  test "a member cannot loosen to leader; an admin can", ctx do
    assert {:error, :forbidden} =
             Squads.update(ctx.carol_scope, "carol-team", %{spec_finalize: "leader"})

    assert mode("carol-team") == nil
    assert {:ok, _} = Squads.update(ctx.admin_scope, "carol-team", %{spec_finalize: "leader"})
    assert mode("carol-team") == :leader
  end

  test "saving other fields keeps leader", ctx do
    {:ok, _} = Squads.update(ctx.admin_scope, "carol-team", %{spec_finalize: "leader"})

    assert {:ok, _} =
             Squads.update(ctx.carol_scope, "carol-team", %{
               description: "New description",
               spec_finalize: "leader"
             })

    assert {:ok, _} = Squads.update(ctx.carol_scope, "carol-team", %{description: "Again"})
    assert mode("carol-team") == :leader
  end

  test "an unknown mode is a field error", ctx do
    assert {:error, %Ecto.Changeset{errors: [spec_finalize: _]}} =
             Squads.update(ctx.alice_scope, "web-team", %{spec_finalize: "never"})
  end

  test "creating a squad: approval by its manager, leader by admins only", ctx do
    view = squad_fixture(ctx.carol_scope, %{name: "carol-two", spec_finalize: "approval"})
    assert mode(view.name) == :approval

    lead = Helmsman.AgentsFixtures.managed_agent_fixture(ctx.carol_scope, %{access: "workspace"})

    assert {:error, :forbidden} =
             Squads.create(ctx.carol_scope, %{
               name: "carol-three",
               leader: lead.name,
               members: [],
               spec_finalize: "leader"
             })

    view = squad_fixture(ctx.admin_scope, %{name: "admin-team", spec_finalize: "leader"})
    assert mode(view.name) == :leader
    view = squad_fixture(ctx.admin_scope, %{name: "plain-team"})
    assert mode(view.name) == nil
  end
end
