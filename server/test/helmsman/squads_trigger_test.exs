defmodule Helmsman.SquadsTriggerTest do
  # add-squads 1.4: who may trigger a squad (squads spec "谁能触发小队",
  # decision 5) and the outcome fields of a squad.
  use Helmsman.DataCase, async: true

  import Helmsman.RunsFixtures
  import Helmsman.SquadsFixtures

  alias Helmsman.{Agents, Squads}
  alias Helmsman.Runs.Outcome

  setup do
    squads_fixture()
  end

  defp check(ctx, user), do: Squads.trigger_check(ctx.workspace.id, user.id, ctx.squad.id)

  test "a member blocks", ctx do
    # bob may trigger the leader (workspace), not alice's owner_only keel/qa.
    assert {:error, :unauthorized, ["keel/qa"]} = check(ctx, ctx.bob)
    assert :ok = check(ctx, ctx.alice)
  end

  test "a disabled member does not block", ctx do
    {:ok, _} = Agents.disable(ctx.alice_scope, "keel/qa")
    assert :ok = check(ctx, ctx.bob)
  end

  test "an archived member is no longer a member and does not block", ctx do
    {:ok, _} = Agents.archive(ctx.alice_scope, "keel/qa")
    assert :ok = check(ctx, ctx.bob)
  end

  test "a disabled squad", ctx do
    {:ok, _} = Squads.disable(ctx.alice_scope, "web-team")
    assert {:error, :squad_disabled} = check(ctx, ctx.alice)
  end

  test "a leader that cannot be triggered is listed first", ctx do
    {:ok, _} = Agents.update(ctx.alice_scope, "keel/lead", %{access: "owner_only"})
    assert {:error, :unauthorized, ["keel/lead", "keel/qa"]} = check(ctx, ctx.bob)
  end

  test "a disabled or archived leader", ctx do
    {:ok, _} = Agents.disable(ctx.alice_scope, "keel/lead")
    assert {:error, :agent_disabled} = check(ctx, ctx.alice)
  end

  test "a viewer never may", ctx do
    {viewer, _scope} = member_scope_fixture(ctx.workspace, :viewer)
    {:ok, _} = Agents.update(ctx.alice_scope, "keel/qa", %{access: "workspace"})

    assert {:error, :unauthorized, ["keel/lead", "keel/fe", "keel/review", "keel/qa"]} =
             check(ctx, viewer)
  end

  test "owners and admins do not bypass a member's owner_only", ctx do
    {admin, _scope} = member_scope_fixture(ctx.workspace, :admin)
    assert {:error, :unauthorized, ["keel/qa"]} = check(ctx, admin)

    # carol owns the workspace too: still not keel/qa's owner.
    Repo.update_all(
      from(m in Helmsman.Workspaces.Membership,
        where: m.workspace_id == ^ctx.workspace.id and m.user_id == ^ctx.carol.id
      ),
      set: [role: :owner]
    )

    assert {:error, :unauthorized, ["keel/qa"]} = check(ctx, ctx.carol)
  end

  test "outcomes carry the squad and the refused names" do
    leader = %Helmsman.Actors.Actor{id: 7, name: "keel/lead"}
    outcome = Outcome.squad_skipped(leader, "web-team", :assign, :unauthorized, ["keel/qa"])

    assert %{agent: "keel/lead", squad: "web-team", refused: ["keel/qa"], reason: "unauthorized"} =
             Outcome.view(outcome)

    assert %{"squad" => "web-team", "refused" => ["keel/qa"], "agent_id" => 7} =
             Outcome.stored(outcome)

    queued =
      Outcome.for_squad(
        %Outcome{agent: "keel/lead", trigger: :assign, result: :queued},
        "web-team"
      )

    assert %{squad: "web-team"} = view = Outcome.view(queued)
    refute Map.has_key?(view, :refused)

    plain = Outcome.stored(%Outcome{agent: "keel/dev", trigger: :manual, result: :queued})
    refute Map.has_key?(plain, "squad")
  end
end
