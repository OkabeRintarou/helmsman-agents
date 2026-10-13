defmodule Helmsman.Autopilots.SquadTargetTest do
  # add-autopilots 8.1: a squad as the target of create_task mode
  # (decision 3; specs/autopilot-execution "目标是小队").
  use Helmsman.DataCase, async: true

  import Helmsman.AutopilotsFixtures
  import Helmsman.SquadsFixtures

  alias Helmsman.{Agents, Autopilots, Squads}
  alias Helmsman.Runs.Run
  alias Helmsman.Tasks.Task

  setup do
    squads_fixture(%{
      members: [
        %{name: "keel/fe", role_note: "Writes the frontend"},
        %{name: "keel/review", role_note: "Reviews"}
      ]
    })
  end

  test "the task goes to the squad and its leader runs as the squad", ctx do
    view = autopilot_fixture(ctx.bob_scope, %{agent: "web-team"})
    assert view.agent == %{name: "web-team", kind: "squad"}

    {:ok, record} = Autopilots.run_now(ctx.bob_scope, view.id)
    assert record.status == :started
    task = Repo.get!(Task, record.task_id)
    assert task.assignee_id == ctx.squad_actor.id

    run = Repo.get!(Run, record.run_id)
    assert {run.agent_id, run.squad_id} == {ctx.lead.id, ctx.squad.id}
  end

  test "the source may no longer trigger the squad: failed / unauthorized and disabled", ctx do
    view = autopilot_fixture(ctx.bob_scope, %{agent: "web-team", cron: "0 9 * * *"})
    {:ok, _} = Agents.update(ctx.alice_scope, "keel/fe", %{access: "owner_only"})

    at = autopilot_row(view).next_run_at
    at(at)
    {:ok, record} = Autopilots.Fire.request(view.id, {:schedule, at})
    assert {record.status, record.reason} == {:failed, "unauthorized"}
    assert %{enabled: false, disabled_reason: :unauthorized} = autopilot_row(view)
  end

  test "run_only may not target a squad", ctx do
    assert {:error, changeset} =
             Autopilots.create(ctx.alice_scope, %{
               name: "x",
               agent: "web-team",
               mode: "run_only",
               instructions: "x"
             })

    assert %{agent: ["must be a managed agent"]} = errors_on(changeset)
  end

  test "a disabled squad: failed / squad_disabled, one failure, not disabled", ctx do
    view = autopilot_fixture(ctx.alice_scope, %{agent: "web-team"})
    {:ok, _} = Squads.disable(ctx.alice_scope, "web-team")

    {:ok, record} = Autopilots.run_now(ctx.alice_scope, view.id)
    assert {record.status, record.reason} == {:failed, "squad_disabled"}
    assert %{enabled: true, consecutive_failures: 1} = autopilot_row(view)
    {:ok, got} = Autopilots.get(ctx.alice_scope, view.id)
    assert :squad_disabled in got.warnings
  end

  describe "managing needs the squad's access, whether its leader is available or not" do
    setup ctx do
      # keel/qa (owner_only, alice's) leads a squad without members.
      squad_fixture(ctx.alice_scope, %{name: "qa-team", leader: "keel/qa", members: []})
      view = autopilot_fixture(ctx.alice_scope, %{agent: "qa-team"})
      Map.put(ctx, :view, view)
    end

    defp manage_ops(ctx, scope) do
      [
        Autopilots.create(scope, %{
          name: "x-#{System.unique_integer([:positive])}",
          agent: "qa-team",
          project: ctx.project.key,
          mode: "create_task",
          title_template: "T",
          instructions: "x"
        }),
        Autopilots.update(scope, ctx.view.id, %{instructions: "y"}),
        Autopilots.enable(scope, ctx.view.id),
        Autopilots.enable_webhook(scope, ctx.view.id),
        Autopilots.rotate_webhook_token(scope, ctx.view.id),
        Autopilots.run_now(scope, ctx.view.id)
      ]
    end

    for change <- [:disable, :archive] do
      @change change
      test "the leader #{change}d: a member or admin who may not trigger it is refused", ctx do
        {:ok, _} = apply(Agents, @change, [ctx.alice_scope, "keel/qa"])

        for scope <- [ctx.bob_scope, ctx.carol_scope] do
          assert Enum.all?(manage_ops(ctx, scope), &(&1 == {:error, :forbidden}))
          {:ok, got} = Autopilots.get(scope, ctx.view.id)
          assert got.permissions == %{manage: false, run: false, disable: false}
        end

        # The owner still manages it.
        assert {:ok, _} = Autopilots.update(ctx.alice_scope, ctx.view.id, %{instructions: "z"})
      end
    end

    test "a workspace leader with an owner_only active member is refused", ctx do
      {:ok, _} =
        Squads.update(ctx.alice_scope, "web-team", %{
          members: [%{name: "keel/fe", role_note: ""}, %{name: "keel/qa", role_note: ""}]
        })

      {:ok, _} = Agents.disable(ctx.alice_scope, "keel/lead")
      view = autopilot_fixture(ctx.alice_scope, %{agent: "web-team"})

      assert Autopilots.update(ctx.bob_scope, view.id, %{instructions: "y"}) ==
               {:error, :forbidden}

      assert Autopilots.run_now(ctx.bob_scope, view.id) == {:error, :forbidden}
    end
  end
end
