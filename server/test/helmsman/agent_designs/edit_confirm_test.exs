defmodule Helmsman.AgentDesigns.EditConfirmTest do
  # add-edit-design-conversations 1.4: agent-design 「确认修改」
  # (decisions 8, 9, 13).
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

  # An edit conversation of `scope` on `target` whose first turn is over.
  defp settled(ctx, scope, target) do
    %{id: id} = start_edit!(scope, target)
    end_and_settle!(run_turn!(ctx, id), :succeeded, summary: "ok")
    id
  end

  defp version(id), do: design!(id).draft_version

  defp put!(scope, id, attrs) do
    {:ok, view} = AgentDesigns.put_agent(scope, id, version(id), Map.put(attrs, "name", "fe-dev"))
    view
  end

  defp put_squad!(scope, id, attrs) do
    {:ok, view} = AgentDesigns.put_squad(scope, id, version(id), attrs)
    view
  end

  defp confirm(scope, id), do: AgentDesigns.confirm(scope, id, version(id))

  defp fe_dev(ctx), do: profile(ctx.fe_dev)

  describe "agent_edit" do
    setup ctx do
      {:ok, _} =
        Agents.update(ctx.alice_scope, "fe-dev", %{
          env: %{"TOKEN" => "s3cret"},
          custom_args: ["--verbose"],
          extra_mcp_servers: %{"x" => %{"command" => "x"}}
        })

      %{id: settled(ctx, ctx.alice_scope, "fe-dev")}
    end

    test "only the changed fields are written", ctx do
      before = fe_dev(ctx)
      put!(ctx.alice_scope, ctx.id, %{"model" => "opus", "instructions" => "New."})

      assert {:ok, %{design: view, agents: [%{name: "fe-dev"}], squad: nil}} =
               confirm(ctx.alice_scope, ctx.id)

      after_ = fe_dev(ctx)
      assert after_.model == "opus" and after_.instructions == "New."
      assert after_.env == before.env and after_.custom_args == before.custom_args
      assert after_.extra_mcp_servers == before.extra_mcp_servers
      assert after_.effort == before.effort and after_.description == before.description

      assert view.status == :confirmed

      assert Enum.sort_by(design!(ctx.id).applied, & &1["field"]) == [
               %{"field" => "instructions", "from" => before.instructions, "to" => "New."},
               %{"field" => "model", "from" => "sonnet", "to" => "opus"}
             ]
    end

    test "changed by someone else meanwhile: rebaselined, nothing written, then confirmed",
         ctx do
      put!(ctx.alice_scope, ctx.id, %{"effort" => "medium"})
      {:ok, _} = Agents.update(ctx.alice_scope, "fe-dev", %{max_concurrency: 4, effort: "low"})
      v = version(ctx.id)

      assert {:error, {:baseline_changed, ["effort", "max_concurrency"]}} =
               confirm(ctx.alice_scope, ctx.id)

      assert %{effort: "low", max_concurrency: 4} = fe_dev(ctx)
      d = design!(ctx.id)
      assert d.status == :open and d.draft_version == v + 1
      assert d.baseline["agent"]["effort"] == "low"
      assert d.baseline["agent"]["max_concurrency"] == 4

      assert %{"effort" => "medium", "max_concurrency" => 4, "conflicts" => ["effort"]} =
               hd(d.draft["agents"])

      assert %{code: "baseline_changed", detail: "effort, max_concurrency"} =
               List.last(messages!(ctx.id))

      assert %{"baseline" => ["effort", "max_concurrency"]} in d.pending_edits

      {:ok, view} = AgentDesigns.get(ctx.alice_scope, ctx.id)
      assert view.conflicts == ["effort"]

      assert {:ok, _} = confirm(ctx.alice_scope, ctx.id)
      assert %{effort: "medium", max_concurrency: 4} = fe_dev(ctx)
    end

    test "a conflict does not block; writing the field again clears it", ctx do
      put!(ctx.alice_scope, ctx.id, %{"effort" => "medium"})
      {:ok, _} = Agents.update(ctx.alice_scope, "fe-dev", %{effort: "low"})
      assert {:error, {:baseline_changed, ["effort"]}} = confirm(ctx.alice_scope, ctx.id)

      view = put!(ctx.alice_scope, ctx.id, %{"effort" => "high"})
      assert view.conflicts == []
      assert {:ok, _} = confirm(ctx.alice_scope, ctx.id)
      assert fe_dev(ctx).effort == "high"
    end

    test "no changes", ctx do
      assert {:error, :no_changes} = confirm(ctx.alice_scope, ctx.id)
      assert design!(ctx.id).status == :open
    end

    test "a new runtime takes the queued runs; nil unbinds and cancels them", ctx do
      {daemon, _} =
        Helmsman.AgentsFixtures.daemon_fixture(ctx.alice, %{workspace_ids: [ctx.workspace.id]})

      runtime =
        Helmsman.AgentsFixtures.runtime_fixture(ctx.workspace, daemon, %{
          provider: "claude",
          models: ["sonnet"],
          efforts: ["high"]
        })

      queued = run_fixture(ctx.fe_dev)
      put!(ctx.alice_scope, ctx.id, %{"runtime_id" => runtime.id})
      assert {:ok, _} = confirm(ctx.alice_scope, ctx.id)
      assert Repo.get!(Run, queued.id).runtime_id == runtime.id

      id = settled(ctx, ctx.alice_scope, "fe-dev")
      put!(ctx.alice_scope, id, %{"runtime_id" => nil})
      assert {:ok, _} = confirm(ctx.alice_scope, id)
      assert Repo.get!(Run, queued.id).status == :cancelled
    end

    test "the target archived meanwhile: not_found", ctx do
      put!(ctx.alice_scope, ctx.id, %{"model" => "opus"})
      {:ok, _} = Agents.archive(ctx.alice_scope, "fe-dev")
      assert {:error, :not_found} = confirm(ctx.alice_scope, ctx.id)
    end

    test "nobody else confirms it", ctx do
      put!(ctx.alice_scope, ctx.id, %{"model" => "opus"})
      assert {:error, :not_found} = confirm(ctx.carol_scope, ctx.id)
      {run_scope, _token} = run_scope_fixture(run_fixture(ctx.fe_dev, %{status: :running}))
      assert {:error, :forbidden} = AgentDesigns.confirm(run_scope, ctx.id, version(ctx.id))
      assert fe_dev(ctx).model == "sonnet"
    end
  end

  describe "agent_edit by an admin who is not the owner" do
    test "the admin fields are written; demoted, the confirm is forbidden", ctx do
      id = settled(ctx, ctx.carol_scope, "fe-dev")
      put!(ctx.carol_scope, id, %{"description" => "Web UI", "max_concurrency" => 3})
      assert {:ok, _} = confirm(ctx.carol_scope, id)
      assert %{description: "Web UI", max_concurrency: 3} = fe_dev(ctx)

      id = settled(ctx, ctx.carol_scope, "fe-dev")
      put!(ctx.carol_scope, id, %{"description" => "Again"})

      Repo.update_all(
        from(m in Membership,
          where: m.workspace_id == ^ctx.workspace.id and m.user_id == ^ctx.carol.id
        ),
        set: [role: :member]
      )

      assert {:error, :forbidden} = AgentDesigns.confirm(ctx.carol_scope, id, version(id))
      assert fe_dev(ctx).description == "Web UI"
    end
  end

  describe "squad_edit" do
    setup ctx do
      %{id: settled(ctx, ctx.alice_scope, "web-team")}
    end

    defp add_qa(ctx) do
      {:ok, _} =
        AgentDesigns.put_agent(ctx.alice_scope, ctx.id, version(ctx.id), %{
          "name" => "qa",
          "provider" => "claude",
          "runtime_id" => ctx.runtime.id,
          "instructions" => "You test end to end."
        })

      members =
        design!(ctx.id).draft["squad"]["members"] ++
          [%{"name" => "qa", "role_note" => "端到端测试"}]

      put_squad!(ctx.alice_scope, ctx.id, %{"members" => members})
    end

    defp members(ctx) do
      {:ok, view} = Squads.get(ctx.alice_scope, "web-team")
      Enum.map(view.members, &{&1.name, &1.role_note})
    end

    test "a new agent and the squad written together", ctx do
      fe_before = fe_dev(ctx)
      add_qa(ctx)

      assert {:ok, %{squad: "web-team", agents: [%{name: "qa"}]}} =
               confirm(ctx.alice_scope, ctx.id)

      qa = agent_actor(ctx.workspace, "qa")
      assert qa.owner_id == ctx.alice.id

      assert members(ctx) == [
               {"fe-dev", "前端"},
               {ctx.bob_name, ""},
               {"qa", "端到端测试"}
             ]

      assert fe_dev(ctx) == fe_before
      d = design!(ctx.id)
      assert d.status == :confirmed and d.created_actor_ids == [qa.id]
      assert [%{"field" => "members"}] = d.applied
    end

    test "the squad changed meanwhile: rebaselined, no new agent, squad unchanged", ctx do
      add_qa(ctx)
      {:ok, _} = Squads.update(ctx.carol_scope, "web-team", %{instructions: "New rules."})

      assert {:error, {:baseline_changed, ["instructions"]}} = confirm(ctx.alice_scope, ctx.id)
      refute Repo.exists?(from(a in Actor, where: a.name == "qa"))
      refute {"qa", "端到端测试"} in members(ctx)
      d = design!(ctx.id)
      assert d.draft["squad"]["instructions"] == "New rules."
      assert d.baseline["squad"]["instructions"] == "New rules."
      refute Map.has_key?(d.draft["squad"], "conflicts")
    end

    test "writing a conflicting field again clears it, even with the same value (code review 1)",
         ctx do
      put_squad!(ctx.alice_scope, ctx.id, %{"instructions" => "A", "description" => "D"})

      {:ok, _} =
        Squads.update(ctx.carol_scope, "web-team", %{instructions: "B", description: "E"})

      assert {:error, {:baseline_changed, ["description", "instructions"]}} =
               confirm(ctx.alice_scope, ctx.id)

      assert design!(ctx.id).draft["squad"]["conflicts"] == ["description", "instructions"]

      # An unrelated field leaves both.
      view = put_squad!(ctx.alice_scope, ctx.id, %{"leader" => "web-lead"})
      assert view.conflicts == ["description", "instructions"]

      # The user, with the draft's own value.
      view = put_squad!(ctx.alice_scope, ctx.id, %{"instructions" => "A"})
      assert view.conflicts == ["description"]
    end

    test "the helper's propose_squad with the same value clears the conflict", ctx do
      put_squad!(ctx.alice_scope, ctx.id, %{"instructions" => "A"})
      {:ok, _} = Squads.update(ctx.carol_scope, "web-team", %{instructions: "B"})
      assert {:error, {:baseline_changed, ["instructions"]}} = confirm(ctx.alice_scope, ctx.id)

      {:ok, _} = AgentDesigns.send(ctx.alice_scope, ctx.id, "keep mine")
      {scope, _token} = design_run_scope!(ctx, ctx.id)
      assert {:ok, _} = AgentDesigns.propose_squad(scope, %{"instructions" => "A"})
      refute Map.has_key?(design!(ctx.id).draft["squad"], "conflicts")
    end

    test "only the squad's other settings changed (renamed): written as is", ctx do
      add_qa(ctx)
      {:ok, _} = Squads.update(ctx.carol_scope, "web-team", %{name: "web-squad"})

      assert {:ok, %{squad: "web-squad"}} = confirm(ctx.alice_scope, ctx.id)
      {:ok, view} = Squads.get(ctx.alice_scope, "web-squad")
      assert "qa" in Enum.map(view.members, & &1.name)
    end

    test "a new agent's name taken meanwhile: nothing written, its name error", ctx do
      add_qa(ctx)

      Helmsman.AgentsFixtures.managed_agent_fixture(ctx.bob_scope, %{
        name: "qa",
        runtime_id: nil
      })

      assert {:error, {:invalid, %{"qa" => cs}}} = confirm(ctx.alice_scope, ctx.id)
      assert Keyword.has_key?(cs.errors, :name)
      assert design!(ctx.id).status == :open
      refute {"qa", "端到端测试"} in members(ctx)
    end

    test "no changes", ctx do
      assert {:error, :no_changes} = confirm(ctx.alice_scope, ctx.id)
    end
  end

  test "changing the leader needs its owner or an admin", ctx do
    Helmsman.AgentsFixtures.managed_agent_fixture(ctx.bob_scope, %{
      name: "bob-lead",
      runtime_id: nil,
      access: "workspace"
    })

    Helmsman.SquadsFixtures.squad_fixture(ctx.bob_scope, %{name: "bob-team", leader: "bob-lead"})
    id = settled(ctx, ctx.bob_scope, "bob-team")

    {:ok, _} =
      AgentDesigns.put_squad(ctx.bob_scope, id, version(id), %{"leader" => "web-lead"})

    assert {:error, {:invalid_squad, cs}} = confirm(ctx.bob_scope, id)
    assert Keyword.has_key?(cs.errors, :leader)
    {:ok, view} = Squads.get(ctx.bob_scope, "bob-team")
    assert view.leader.name == "bob-lead"
  end

  test "an AgentProfile with members access keeps it", ctx do
    {:ok, _} =
      Agents.update(ctx.alice_scope, "fe-dev", %{
        access: "members",
        access_member_ids: [ctx.bob.id]
      })

    id = settled(ctx, ctx.alice_scope, "fe-dev")
    put!(ctx.alice_scope, id, %{"model" => "opus"})
    assert {:ok, _} = confirm(ctx.alice_scope, id)

    assert %AgentProfile{access: "members", access_member_ids: [bob_id]} = fe_dev(ctx)
    assert bob_id == ctx.bob.id
  end
end
