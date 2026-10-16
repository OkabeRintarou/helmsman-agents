defmodule Helmsman.AgentDesigns.EditDraftTest do
  # add-edit-design-conversations 1.3: agent-design 「修改对话的草稿」
  # (decisions 5–7, 10).
  use Helmsman.DataCase, async: true

  import Helmsman.AgentDesignsFixtures
  import Helmsman.RunsFixtures

  alias Helmsman.Actors.Actor
  alias Helmsman.{AgentDesigns, Agents}
  alias Helmsman.AgentDesigns.Changes
  alias Helmsman.Workspaces.Membership

  setup do
    edit_fixture()
  end

  # The helper's turn of the conversation `id`: its run-token scope.
  defp ai(ctx, id) do
    {scope, _token} = design_run_scope!(ctx, id)
    scope
  end

  defp entry(id), do: hd(design!(id).draft["agents"])

  defp field_errors({:error, {:invalid_agent, _name, cs}}), do: cs.errors
  defp field_errors({:error, %Ecto.Changeset{} = cs}), do: cs.errors
  defp field_errors({:error, {:invalid_squad, cs}}), do: cs.errors

  describe "agent_edit, the helper's propose_agent" do
    setup ctx do
      %{id: id} = start_edit!(ctx.alice_scope, "fe-dev")
      %{id: id, ai: ai(ctx, id)}
    end

    test "one field: only it differs; get_design shows sonnet → opus", ctx do
      assert {:ok, %{agent: %{"model" => "opus"}, draft_version: 1}} =
               AgentDesigns.propose_agent(ctx.ai, %{"name" => "fe-dev", "model" => "opus"})

      assert {:ok, d} = AgentDesigns.describe(ctx.ai)
      assert [%{field: "model", from: "sonnet", to: "opus"}] = d.changes
      assert d.target == %{name: "fe-dev", kind: :agent, owner: ctx.alice.display_name}
      assert d.baseline["agent"]["model"] == "sonnet"
      assert d.conflicts == [] and d.readonly == []
      assert Enum.any?(d.options.runtimes, &(&1.id == ctx.runtime.id))

      assert Changes.text(d.changes, 8192) == "model: sonnet → opus"
    end

    test "the name is case-insensitive; the long texts get a line diff", ctx do
      instructions = "You build the web UI.\nUse Tailwind.\nWrite Storybook stories."

      assert {:ok, _} =
               AgentDesigns.propose_agent(ctx.ai, %{
                 "name" => "FE-DEV",
                 "instructions" => instructions
               })

      assert {:ok, %{changes: [%{field: "instructions", diff: diff}]}} =
               AgentDesigns.describe(ctx.ai)

      assert diff =~ "+ Write Storybook stories."
      assert diff =~ "  Use Tailwind."
      assert entry(ctx.id)["name"] == "fe-dev"
    end

    test "no rename: previous_name or another name, the draft unchanged", ctx do
      for attrs <- [
            %{"name" => "fe-dev", "previous_name" => "fe-dev-old"},
            %{"name" => "web-dev", "model" => "opus"}
          ] do
        result = AgentDesigns.propose_agent(ctx.ai, attrs)
        assert [name: {message, _}] = field_errors(result)
        assert message =~ "rename it on the agent's page"
      end

      assert design!(ctx.id).draft_version == 0
    end

    test "disabling, archiving and secrets are refused", ctx do
      result =
        AgentDesigns.propose_agent(ctx.ai, %{
          "name" => "fe-dev",
          "disabled" => true,
          "env" => %{"K" => "v"}
        })

      errors = field_errors(result)
      assert {:env, {"cannot be set in a draft", []}} in errors

      assert Enum.any?(errors, fn
               {:base, {msg, opts}} -> msg =~ "agent's page" and opts[:field] == "disabled"
               _ -> false
             end)
    end

    test "nil restores the default", ctx do
      assert {:ok, _} =
               AgentDesigns.propose_agent(ctx.ai, %{
                 "name" => "fe-dev",
                 "max_concurrency" => 5,
                 "description" => nil
               })

      assert {:ok, _} =
               AgentDesigns.propose_agent(ctx.ai, %{"name" => "fe-dev", "max_concurrency" => nil})

      assert %{"max_concurrency" => 2, "description" => ""} = entry(ctx.id)
    end

    test "access and capabilities rules; members only when the baseline had it", ctx do
      result = AgentDesigns.propose_agent(ctx.ai, %{"name" => "fe-dev", "access" => "members"})
      assert [access: _] = field_errors(result)

      result =
        AgentDesigns.propose_agent(ctx.ai, %{"name" => "fe-dev", "capabilities" => ["delegate"]})

      assert [capabilities: _] = field_errors(result)
    end

    test "the runtime must be the owner's", ctx do
      {_other, other_scope} = member_scope_fixture(ctx.workspace)

      {daemon, _} =
        Helmsman.AgentsFixtures.daemon_fixture(other_scope.user, %{
          workspace_ids: [ctx.workspace.id]
        })

      runtime =
        Helmsman.AgentsFixtures.runtime_fixture(ctx.workspace, daemon, %{provider: "claude"})

      result =
        AgentDesigns.propose_agent(ctx.ai, %{"name" => "fe-dev", "runtime_id" => runtime.id})

      assert Keyword.has_key?(field_errors(result), :runtime_id)
    end

    test "the owner's write result keeps the account ID", ctx do
      account =
        Helmsman.ProviderAccountsFixtures.provider_account_fixture(ctx.alice, %{cli: "claude"})

      assert {:ok, %{agent: agent}} =
               AgentDesigns.propose_agent(ctx.ai, %{
                 "name" => "fe-dev",
                 "provider_account_id" => account.id
               })

      assert agent["provider_account_id"] == account.id
    end

    test "withdraw_agent is not a tool of the kind", ctx do
      assert {:error, {:design, {:wrong_kind, "withdraw_agent", :agent_edit}}} =
               AgentDesigns.withdraw_agent(ctx.ai, "fe-dev")
    end
  end

  describe "agent_edit by an admin who is not the owner" do
    setup ctx do
      %{id: id} = start_edit!(ctx.carol_scope, "fe-dev")
      %{id: id, ai: ai(ctx, id)}
    end

    test "instructions: only the owner can change it", ctx do
      result =
        AgentDesigns.propose_agent(ctx.ai, %{"name" => "fe-dev", "instructions" => "New."})

      assert [instructions: {"only the owner (%{owner}) can change this field", opts}] =
               field_errors(result)

      assert opts[:owner] == ctx.alice.display_name
      assert design!(ctx.id).draft_version == 0
    end

    test "description and the limits are writable", ctx do
      assert {:ok, _} =
               AgentDesigns.propose_agent(ctx.ai, %{
                 "name" => "fe-dev",
                 "description" => "Web UI",
                 "max_concurrency" => 4,
                 "timeout_minutes" => 60,
                 "idle_timeout_minutes" => 10
               })
    end

    test "get_design: the read-only list, no runtimes or accounts, accounts as name and host",
         ctx do
      account =
        Helmsman.ProviderAccountsFixtures.provider_account_fixture(ctx.alice, %{cli: "claude"})

      Repo.update_all(
        from(p in Helmsman.Agents.AgentProfile, where: p.actor_id == ^ctx.fe_dev.id),
        set: [provider_account_id: account.id]
      )

      Repo.update_all(
        from(d in Helmsman.AgentDesigns.AgentDesign, where: d.id == ^ctx.id),
        set: [
          baseline: %{"agent" => Map.put(entry(ctx.id), "provider_account_id", account.id)}
        ]
      )

      assert {:ok, d} = AgentDesigns.describe(ctx.ai)
      assert "instructions" in d.readonly and "runtime_id" in d.readonly
      refute Map.has_key?(d.options, :runtimes)
      refute Map.has_key?(d.options, :provider_accounts)
      refute Map.has_key?(d.baseline["agent"], "provider_account_id")
      assert %{"name" => _, "host" => _} = d.baseline["agent"]["provider_account"]
      refute Map.has_key?(hd(d.draft["agents"]), "provider_account_id")

      {:ok, view} = AgentDesigns.get(ctx.carol_scope, ctx.id)
      refute Map.has_key?(view.baseline["agent"], "provider_account_id")
    end

    test "a write's result shows the owner's account as name and host only (code review 1)",
         ctx do
      account =
        Helmsman.ProviderAccountsFixtures.provider_account_fixture(ctx.alice, %{cli: "claude"})

      Repo.update_all(
        from(d in Helmsman.AgentDesigns.AgentDesign, where: d.id == ^ctx.id),
        set: [
          draft: %{"agents" => [Map.put(entry(ctx.id), "provider_account_id", account.id)]}
        ]
      )

      assert {:ok, %{agent: agent}} =
               AgentDesigns.propose_agent(ctx.ai, %{"name" => "fe-dev", "description" => "Web"})

      refute Map.has_key?(agent, "provider_account_id")
      assert %{"name" => name, "host" => _} = agent["provider_account"]
      assert name == account.name

      assert {:ok, json} =
               HelmsmanMCP.Pipeline.call_tool(
                 "propose_agent",
                 %{"name" => "fe-dev", "description" => "Web UI"},
                 ctx.ai,
                 nil
               )

      refute json =~ "provider_account_id"
      refute json =~ ~s("#{account.id}")
      assert json =~ account.name
    end

    test "demoted to member: the next write is forbidden", ctx do
      Repo.update_all(
        from(m in Membership,
          where: m.workspace_id == ^ctx.workspace.id and m.user_id == ^ctx.carol.id
        ),
        set: [role: :member]
      )

      assert {:error, :forbidden} =
               AgentDesigns.propose_agent(ctx.ai, %{"name" => "fe-dev", "description" => "x"})
    end
  end

  describe "agent_edit, the user" do
    setup ctx do
      %{id: id} = start_edit!(ctx.alice_scope, "fe-dev")
      run = run_turn!(ctx, id)
      end_and_settle!(run, :succeeded, summary: "ok")
      %{id: id}
    end

    test "the same rules; reverting a field to the baseline; pending edits", ctx do
      assert {:ok, view} =
               AgentDesigns.put_agent(ctx.alice_scope, ctx.id, 0, %{
                 "name" => "fe-dev",
                 "model" => "opus",
                 "effort" => "low"
               })

      assert [%{"agent" => "fe-dev", "fields" => ["effort", "model"]}] = view.pending_edits
      assert length(view.changes) == 2

      assert {:ok, view} = AgentDesigns.revert_field(ctx.alice_scope, ctx.id, 1, "agent", "model")
      assert [%{field: "effort"}] = view.changes
      assert hd(view.draft["agents"])["model"] == "sonnet"

      assert {:error, :not_a_field} =
               AgentDesigns.revert_field(ctx.alice_scope, ctx.id, 2, "agent", "env")

      assert {:error, %Ecto.Changeset{}} =
               AgentDesigns.put_agent(ctx.alice_scope, ctx.id, 2, %{"name" => "renamed"})

      assert {:error, :not_removable} =
               AgentDesigns.remove_agent(ctx.alice_scope, ctx.id, 2, "fe-dev")
    end

    test "the target renamed meanwhile: its current and its old name both work", ctx do
      Repo.update_all(from(a in Actor, where: a.id == ^ctx.fe_dev.id), set: [name: "ui-dev"])

      for name <- ["ui-dev", "fe-dev"] do
        assert {:ok, _} =
                 AgentDesigns.put_agent(
                   ctx.alice_scope,
                   ctx.id,
                   design!(ctx.id).draft_version,
                   %{"name" => name, "effort" => "medium"}
                 )
      end

      {:ok, view} = AgentDesigns.get(ctx.alice_scope, ctx.id)
      assert view.target.name == "ui-dev"
    end
  end

  describe "squad_edit" do
    setup ctx do
      %{id: id} = start_edit!(ctx.alice_scope, "web-team")
      %{id: id, ai: ai(ctx, id)}
    end

    defp qa(ctx) do
      AgentDesigns.propose_agent(ctx.ai, %{
        "name" => "qa",
        "provider" => "claude",
        "runtime_id" => ctx.runtime.id,
        "instructions" => "You test end to end."
      })
    end

    test "a new member: a new agent in the draft, members added qa, no new identity", ctx do
      assert {:ok, _} = qa(ctx)

      members =
        design!(ctx.id).draft["squad"]["members"] ++
          [%{"name" => "qa", "role_note" => "端到端测试"}]

      assert {:ok, _} = AgentDesigns.propose_squad(ctx.ai, %{"members" => members})

      assert {:ok, d} = AgentDesigns.describe(ctx.ai)
      assert [%{field: "members", added: ["qa"], removed: [], notes: []}] = d.changes
      assert [%{"name" => "qa"}] = d.draft["agents"]
      refute Repo.exists?(from(a in Actor, where: a.name == "qa"))
    end

    test "an existing member cannot be changed through it", ctx do
      result = AgentDesigns.propose_agent(ctx.ai, %{"name" => "fe-dev", "model" => "opus"})
      assert [name: {message, _}] = field_errors(result)
      assert message =~ "edit it in its own conversation"
    end

    test "the squad's name is fixed; the same name is fine", ctx do
      result = AgentDesigns.propose_squad(ctx.ai, %{"name" => "mobile-team"})
      assert [name: {message, _}] = field_errors(result)
      assert message =~ "rename it on the squad's page"

      assert {:ok, _} =
               AgentDesigns.propose_squad(ctx.ai, %{
                 "name" => "Web-Team",
                 "instructions" => "Ship it."
               })

      assert {:ok, %{changes: [%{field: "instructions"}]}} = AgentDesigns.describe(ctx.ai)
      assert design!(ctx.id).draft["squad"]["name"] == "web-team"
    end

    test "withdraw_agent only reaches new agents", ctx do
      assert {:error, {:not_in_draft, "fe-dev"}} = AgentDesigns.withdraw_agent(ctx.ai, "fe-dev")
      assert {:ok, _} = qa(ctx)
      assert {:ok, %{removed: "qa"}} = AgentDesigns.withdraw_agent(ctx.ai, "qa")
    end

    test "get_design: the squad hint and the people", ctx do
      assert {:ok, d} = AgentDesigns.describe(ctx.ai)
      assert %{able: _, total: _} = d.trigger_summary
      assert Enum.any?(d.options.people, &(&1.name == ctx.bob_name))
      assert d.target.kind == :squad
    end
  end

  test "an agent archived after the start: the next write is forbidden", ctx do
    %{id: id} = start_edit!(ctx.alice_scope, "fe-dev")
    scope = ai(ctx, id)
    {:ok, _} = Agents.archive(ctx.alice_scope, "fe-dev")

    assert {:error, :forbidden} =
             AgentDesigns.propose_agent(scope, %{"name" => "fe-dev", "model" => "opus"})
  end
end
