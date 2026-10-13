defmodule Helmsman.SquadsTest do
  # add-squads 1.2: squads and their members, who may manage them, the
  # hint when saving, reading and notifications (squads spec).
  use Helmsman.DataCase, async: true

  import Helmsman.AgentsFixtures
  import Helmsman.RunsFixtures
  import Helmsman.SquadsFixtures

  alias Helmsman.{Actors, Agents, Events, Squads, Tx}
  alias Helmsman.Actors.Actor
  alias Helmsman.Squads.Squad

  setup do
    squads_fixture()
  end

  defp errors(%Ecto.Changeset{} = cs), do: Agents.errors(cs)

  defp squad_count(ws), do: Repo.aggregate(from(s in Squad, where: s.workspace_id == ^ws), :count)

  describe "squads and members" do
    test "creating a squad gives its leader and members in order", ctx do
      assert ctx.squad.name == "web-team"
      assert %Actor{kind: :squad} = ctx.squad_actor

      assert {:ok, squad} = Squads.get(ctx.alice_scope, "web-team")

      assert %{name: "keel/lead", provider: "claude", model: "opus", effort: "high"} =
               squad.leader

      assert squad.leader.owner.id == ctx.alice.id

      assert [
               %{
                 name: "keel/fe",
                 kind: "agent",
                 role_note: "Writes the frontend",
                 model: "sonnet"
               },
               %{name: "keel/review", kind: "agent", effort: "medium"},
               %{name: "keel/qa", kind: "agent", model: "haiku", effort: "low"},
               %{kind: "human", role_note: "Decides product questions", provider: nil}
             ] = squad.members

      # The four agents share one runtime.
      assert Enum.uniq(Enum.map([ctx.lead, ctx.fe, ctx.review, ctx.qa], &profile(&1).runtime_id)) ==
               [ctx.runtime_id]
    end

    test "an external agent cannot lead", ctx do
      {:ok, _} = Actors.identify(%{ctx.alice_scope | via: :mcp}, %{name: "claude-desktop"})
      count = squad_count(ctx.workspace.id)

      assert {:error, cs} =
               Squads.create(ctx.alice_scope, %{name: "desk-team", leader: "claude-desktop"})

      assert %{leader: [_]} = errors(cs)
      assert squad_count(ctx.workspace.id) == count
      refute Repo.get_by(Actor, workspace_id: ctx.workspace.id, name: "desk-team")
    end

    test "the leader or the system identity as a member", ctx do
      for name <- ["keel/lead", "helmsman", "web-team"] do
        assert {:error, cs} =
                 Squads.update(ctx.alice_scope, "web-team", %{members: [%{name: name}]})

        assert %{members: [_]} = errors(cs)
      end

      assert {:error, cs} =
               Squads.update(ctx.alice_scope, "web-team", %{
                 members: [%{name: "keel/fe"}, %{name: "keel/fe"}]
               })

      assert %{members: [_]} = errors(cs)

      assert {:ok, %{members: members}} = Squads.get(ctx.alice_scope, "web-team")
      assert length(members) == 4
    end

    test "lengths are counted in bytes", ctx do
      long = String.duplicate("😀", 600)

      assert {:error, cs} =
               Squads.update(ctx.alice_scope, "web-team", %{
                 members: [%{name: "keel/fe", role_note: long}]
               })

      assert %{members: [_]} = errors(cs)

      assert {:error, cs} = Squads.update(ctx.alice_scope, "web-team", %{description: long})
      assert %{description: [_]} = errors(cs)

      chinese = String.duplicate("写前端", 227)
      assert byte_size(chinese) <= 2048

      assert {:ok, squad} =
               Squads.update(ctx.alice_scope, "web-team", %{
                 description: chinese,
                 members: [%{name: "keel/fe", role_note: chinese}]
               })

      assert squad.description == chinese
      assert [%{role_note: ^chinese}] = squad.members
    end

    test "the name is taken, whatever the case", ctx do
      assert {:error, cs} =
               Squads.create(ctx.alice_scope, %{name: "keel/dev", leader: "keel/lead"})

      assert %{name: [_]} = errors(cs)

      assert {:error, cs} =
               Squads.create(ctx.alice_scope, %{name: "KEEL/DEV", leader: "keel/lead"})

      assert %{name: [_]} = errors(cs)
    end

    test "an unclaimed human identity may be a member", ctx do
      Repo.insert!(%Actor{workspace_id: ctx.workspace.id, kind: :human, name: "imported-dan"})

      assert {:ok, %{members: [%{name: "imported-dan", kind: "human"}]}} =
               Squads.update(ctx.alice_scope, "web-team", %{members: [%{name: "imported-dan"}]})
    end

    test "saving with a disabled leader; reading shows it", ctx do
      {:ok, _} = Agents.disable(ctx.alice_scope, "keel/lead")

      assert {:ok, %{leader: %{disabled: true, archived: false}}} =
               Squads.update(ctx.alice_scope, "web-team", %{description: "still here"})
    end

    test "after a rename the old name is free", ctx do
      assert {:ok, %{name: "web-squad"}} =
               Squads.update(ctx.alice_scope, "web-team", %{name: "web-squad"})

      assert {:error, :not_found} = Squads.get(ctx.alice_scope, "web-team")
      agent = managed_agent_fixture(ctx.bob_scope, %{name: "web-team"})
      assert agent.name == "web-team"
    end
  end

  describe "who may manage a squad" do
    setup ctx do
      # bob (member) leads his own squad with his agent bob/lead.
      managed_agent_fixture(ctx.bob_scope, %{name: "bob/lead", access: "workspace"})
      managed_agent_fixture(ctx.carol_scope, %{name: "carol/qa", access: "workspace"})
      managed_agent_fixture(ctx.carol_scope, %{name: "carol/lead", access: "workspace"})
      squad_fixture(ctx.bob_scope, %{name: "bob-team", leader: "bob/lead"})
      :ok
    end

    test "the member who owns the leader", ctx do
      assert {:ok, %{members: [%{name: "carol/qa"}]}} =
               Squads.update(ctx.bob_scope, "bob-team", %{members: [%{name: "carol/qa"}]})
    end

    test "another member", ctx do
      assert {:error, :forbidden} =
               Squads.update(ctx.carol_scope, "bob-team", %{description: "mine now"})

      assert {:error, :forbidden} = Squads.disable(ctx.carol_scope, "bob-team")
      assert {:ok, %{description: ""}} = Squads.get(ctx.alice_scope, "bob-team")
    end

    test "creating with someone else's agent as the leader", ctx do
      assert {:error, :forbidden} =
               Squads.create(ctx.bob_scope, %{name: "x-team", leader: "carol/lead"})
    end

    test "making someone else's agent the leader", ctx do
      assert {:error, :forbidden} =
               Squads.update(ctx.bob_scope, "bob-team", %{leader: "carol/lead"})

      {_admin, admin_scope} = member_scope_fixture(ctx.workspace, :admin)

      assert {:ok, %{leader: %{name: "carol/lead"}}} =
               Squads.update(admin_scope, "bob-team", %{leader: "carol/lead"})
    end

    test "can_manage in the views (#36 domain-request-1 R1)", ctx do
      {_admin, admin_scope} = member_scope_fixture(ctx.workspace, :admin)
      {_viewer, viewer_scope} = member_scope_fixture(ctx.workspace, :viewer)

      assert {:ok, %{can_manage: true}} = Squads.get(ctx.bob_scope, "bob-team")
      assert {:ok, %{can_manage: false}} = Squads.get(ctx.carol_scope, "bob-team")
      assert {:ok, %{can_manage: true}} = Squads.get(admin_scope, "bob-team")
      assert {:ok, %{can_manage: false}} = Squads.get(viewer_scope, "bob-team")
    end

    test "viewers and agents", ctx do
      {_viewer, viewer_scope} = member_scope_fixture(ctx.workspace, :viewer)
      assert {:error, :forbidden} = Squads.update(viewer_scope, "bob-team", %{description: "x"})
      assert {:ok, _} = Squads.get(viewer_scope, "bob-team")
      assert {:ok, [_, _]} = Squads.list(viewer_scope)

      agent_scope = %{ctx.alice_scope | actor: ctx.lead}
      assert {:error, :forbidden} = Squads.update(agent_scope, "web-team", %{description: "x"})
    end

    test "a leader run cannot change squads or create agents", ctx do
      task = Helmsman.ProjectsFixtures.task_fixture(ctx.alice_scope, ctx.project.key)

      run =
        run_fixture(ctx.lead, %{
          task_id: task.id,
          status: :running,
          squad_id: ctx.squad.id,
          capabilities: ["read", "write_task", "create_tasks", "delegate"]
        })

      {scope, _token} = run_scope_fixture(run)

      assert {:error, :forbidden} = Squads.update(scope, "web-team", %{description: "x"})
      assert {:error, :forbidden} = Squads.create(scope, %{name: "y-team", leader: "keel/lead"})
      assert {:error, :forbidden} = Squads.disable(scope, "web-team")
      assert {:error, :forbidden} = Agents.create(scope, %{name: "keel/new", provider: "claude"})
    end

    test "a stale version", ctx do
      {:ok, %{lock_version: v}} = Squads.get(ctx.alice_scope, "web-team")

      assert {:ok, %{lock_version: v2}} =
               Squads.update(ctx.alice_scope, "web-team", %{lock_version: v, description: "a"})

      assert v2 == v + 1

      assert {:error, :stale} =
               Squads.update(ctx.alice_scope, "web-team", %{lock_version: v, description: "b"})

      assert {:ok, %{description: "a"}} = Squads.get(ctx.alice_scope, "web-team")

      # Without a version the last write wins.
      assert {:ok, %{description: "c"}} =
               Squads.update(ctx.alice_scope, "web-team", %{description: "c"})
    end
  end

  describe "the hint when saving" do
    test "an owner_only member", ctx do
      member_scope_fixture(ctx.workspace)
      member_scope_fixture(ctx.workspace, :viewer)

      assert {:ok, %{trigger_summary: summary}} =
               Squads.update(ctx.alice_scope, "web-team", %{description: "x"})

      assert summary == %{able: 1, total: 4, restricted: ["keel/qa"]}
    end

    test "it does not prevent saving", ctx do
      assert {:ok, %{trigger_summary: %{restricted: ["keel/qa"]}}} =
               Squads.create(ctx.alice_scope, %{
                 name: "qa-team",
                 leader: "keel/lead",
                 members: [%{name: "keel/qa"}]
               })
    end
  end

  describe "reading and notifications" do
    test "the assignee picker", ctx do
      assert {:ok, %{"web-team" => {:skipped, :unauthorized, ["keel/qa"]}}} =
               Squads.availability(ctx.bob_scope)

      assert {:ok, %{"web-team" => :ok}} = Squads.availability(ctx.alice_scope)

      assert {:ok, actors} = Actors.list_assignable(ctx.bob_scope)
      assert List.last(actors).name == "web-team"
      assert List.last(actors).kind == :squad
    end

    test "a disabled squad is not assignable", ctx do
      {:ok, %{disabled: true}} = Squads.disable(ctx.alice_scope, "web-team")
      {:ok, actors} = Actors.list_assignable(ctx.bob_scope)
      refute Enum.any?(actors, &(&1.name == "web-team"))

      assert {:ok, %{"web-team" => {:skipped, :squad_disabled, []}}} =
               Squads.availability(ctx.bob_scope)
    end

    test "notified after the commit, not on rollback", ctx do
      Events.subscribe(Squads.topic(ctx.workspace.id))
      id = ctx.squad.id

      assert {:error, :rollback} =
               Tx.run(fn ->
                 {:ok, _} = Squads.update(ctx.alice_scope, "web-team", %{instructions: "y"})
                 {:error, :rollback}
               end)

      refute_receive {:squad, ^id}

      assert {:ok, %{instructions: "Ship small pull requests."}} =
               Squads.get(ctx.alice_scope, "web-team")

      {:ok, _} = Squads.update(ctx.alice_scope, "web-team", %{instructions: "x"})
      assert_receive {:squad, ^id}
    end
  end
end
