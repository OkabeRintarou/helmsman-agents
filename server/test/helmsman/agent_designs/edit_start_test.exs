defmodule Helmsman.AgentDesigns.EditStartTest do
  # add-edit-design-conversations 1.3: agent-design 「开始修改对话」
  # (decisions 4, 5).
  use Helmsman.DataCase, async: true

  import Helmsman.AgentDesignsFixtures
  import Helmsman.RunsFixtures

  alias Helmsman.{AgentDesigns, Agents}
  alias Helmsman.AgentDesigns.AgentDesign
  alias Helmsman.Runs.Run

  setup do
    edit_fixture()
  end

  defp start(scope, target),
    do: AgentDesigns.start_edit(scope, %{target: target, helper: "helper", message: "改用 opus"})

  defp nothing_written(ctx) do
    assert Repo.aggregate(AgentDesign, :count) == 0
    assert Repo.aggregate(from(r in Run, where: r.agent_id == ^ctx.helper.id), :count) == 0
  end

  describe "agent_edit" do
    test "the owner: baseline and draft are the agent's configuration; a design run", ctx do
      assert {:ok, view} = start(ctx.alice_scope, "fe-dev")
      assert %{kind: :agent_edit, target: %{name: "fe-dev", kind: :agent}} = view

      profile = profile(ctx.fe_dev)

      expected = %{
        "name" => "fe-dev",
        "provider" => "claude",
        "description" => "Builds the web UI",
        "runtime_id" => ctx.runtime.id,
        "provider_account_id" => nil,
        "model" => "sonnet",
        "effort" => "high",
        "instructions" => "You build the web UI.\nUse Tailwind.",
        "capabilities" => [],
        "access" => profile.access,
        "max_concurrency" => profile.max_concurrency,
        "timeout_minutes" => profile.timeout_minutes,
        "idle_timeout_minutes" => profile.idle_timeout_minutes
      }

      assert view.baseline == %{"agent" => expected}
      assert [entry] = view.draft["agents"]
      assert Map.delete(entry, "updated_by") == expected
      assert view.changes == [] and view.conflicts == [] and view.readonly == []

      row = design!(view.id)
      assert row.slot == :edit and row.target_actor_id == ctx.fe_dev.id
      run = Repo.get!(Run, view.current_run.id)
      assert run.agent_id == ctx.helper.id and run.status == :queued
      assert [%{"kind" => "design"}] = run.triggers
    end

    test "an admin who is not the owner: only description, concurrency and timeouts", ctx do
      assert {:ok, view} = start(ctx.carol_scope, "fe-dev")

      assert Enum.sort(view.readonly) ==
               Enum.sort(~w(provider runtime_id provider_account_id model effort instructions
                            capabilities access))
    end

    test "a member who is not the owner: forbidden, nothing written", ctx do
      assert {:error, :forbidden} = start(ctx.bob_scope, "fe-dev")
      nothing_written(ctx)
    end

    test "an archived agent, an external agent, a person, nobody: not_found", ctx do
      Helmsman.AgentsFixtures.managed_agent_fixture(ctx.alice_scope, %{
        name: "old-bot",
        runtime_id: ctx.runtime.id
      })

      {:ok, _} = Agents.archive(ctx.alice_scope, "old-bot")

      Repo.insert!(%Helmsman.Actors.Actor{
        workspace_id: ctx.workspace.id,
        kind: :agent,
        name: "outside",
        owner_id: ctx.alice.id
      })

      for target <- ["old-bot", "outside", ctx.bob_name, "nobody", nil] do
        assert {:error, :not_found} = start(ctx.alice_scope, target)
      end

      nothing_written(ctx)
    end

    test "a viewer, a run token and an API token: forbidden", ctx do
      assert {:error, :forbidden} = start(ctx.dan_scope, "fe-dev")

      run = run_fixture(ctx.fe_dev, %{status: :running, daemon_id: ctx.daemon.id})
      {run_scope, _token} = run_scope_fixture(run)
      assert {:error, :forbidden} = start(run_scope, "fe-dev")

      token_scope =
        Helmsman.ApiTokensFixtures.token_scope_fixture(ctx.alice, ctx.workspace, :token)

      assert {:error, :forbidden} = start(token_scope, "fe-dev")
      assert Repo.aggregate(AgentDesign, :count) == 0
    end

    test "access members is kept as members in the baseline", ctx do
      {:ok, _} =
        Agents.update(ctx.alice_scope, "fe-dev", %{
          access: "members",
          access_member_ids: [ctx.bob.id]
        })

      assert {:ok, view} = start(ctx.alice_scope, "fe-dev")
      assert view.baseline["agent"]["access"] == "members"
      refute Map.has_key?(view.baseline["agent"], "access_member_ids")
    end

    test "the helper cannot be dispatched: no conversation", ctx do
      {:ok, _} = Agents.disable(ctx.alice_scope, "helper")
      assert {:error, :agent_disabled} = start(ctx.alice_scope, "fe-dev")
      nothing_written(ctx)
    end
  end

  describe "squad_edit" do
    test "who may manage it: the baseline is the squad's part and lock_version", ctx do
      assert {:ok, view} = start(ctx.alice_scope, "web-team")
      assert %{kind: :squad_edit, target: %{name: "web-team", kind: :squad}} = view

      assert %{
               "squad" => %{
                 "description" => "The web squad",
                 "instructions" => "Ship the web app.",
                 "leader" => "web-lead",
                 "members" => [
                   %{"name" => "fe-dev", "role_note" => "前端"},
                   %{"name" => bob, "role_note" => ""}
                 ]
               },
               "lock_version" => version
             } = view.baseline

      assert bob == ctx.bob_name and is_integer(version)
      assert view.draft["agents"] == []
      assert view.draft["squad"]["name"] == "web-team"
      assert Map.delete(view.draft["squad"], "name") == view.baseline["squad"]
      assert view.changes == []
    end

    test "an admin may; a member who does not own the leader may not", ctx do
      assert {:ok, _} = start(ctx.carol_scope, "web-team")
      assert {:error, :forbidden} = start(ctx.bob_scope, "web-team")
    end
  end
end
