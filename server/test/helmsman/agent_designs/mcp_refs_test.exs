defmodule Helmsman.AgentDesigns.McpRefsTest do
  use Helmsman.DataCase, async: true
  import Helmsman.AgentDesignsFixtures
  import Helmsman.RunsFixtures
  alias Helmsman.AgentDesigns
  alias Helmsman.AgentDesigns.{Draft, Edit, Prompt}
  alias Helmsman.{Agents, McpServers}

  test "creation prompt and get_design offer names and program only; deleting a draft reference blocks confirmation" do
    ctx = design_fixture()

    {:ok, definition} =
      McpServers.create(ctx.alice_scope, %{
        name: "docs",
        config: %{
          "command" => "/local/bin/npx",
          "args" => ["DRAFT_ARG_CANARY"],
          "auth" => "DRAFT_SECRET_CANARY"
        }
      })

    %{id: id} = start_design!(ctx.alice_scope)
    prompt = Prompt.for_run(current_run!(id))
    assert prompt =~ "docs (stdio, npx)"
    refute prompt =~ "DRAFT_ARG_CANARY"
    refute prompt =~ "DRAFT_SECRET_CANARY"
    {scope, _} = design_run_scope!(ctx, id)
    assert {:ok, design} = AgentDesigns.describe(scope)
    assert [%{name: "docs", type: "stdio", program: "npx"}] = design.options.mcp_servers
    refute inspect(design.options) =~ "DRAFT_ARG_CANARY"
    refute inspect(design.options) =~ "DRAFT_SECRET_CANARY"

    assert {:ok, _, entry, _} =
             Draft.put(
               %{},
               %{
                 name: "new-agent",
                 provider: "claude",
                 instructions: "Use docs",
                 mcp_servers: ["docs"]
               },
               ctx.alice_scope,
               "ai"
             )

    assert {:ok, :deleted} = McpServers.delete(ctx.alice_scope, definition.id)
    assert {:error, cs} = Draft.create_attrs(entry, ctx.alice_scope)
    assert cs.errors[:mcp_servers]
  end

  test "drafts accept only owned definition names; renamed/deleted references fail confirmation" do
    ctx = dispatch_fixture()

    {:ok, d} =
      McpServers.create(ctx.alice_scope, %{
        name: "pw",
        config: %{"command" => "npx", "args" => ["PRIVATE_ARG"]}
      })

    attrs = %{name: "fe-dev", provider: "claude", instructions: "Build UI", mcp_servers: ["pw"]}
    assert {:ok, draft, entry, _} = Draft.put(%{}, attrs, ctx.alice_scope, "ai")
    assert {:ok, created_attrs} = Draft.create_attrs(entry, ctx.alice_scope)
    assert {:ok, agent} = Agents.create(ctx.alice_scope, created_attrs)
    assert [%{name: "pw"}] = agent.mcp_server_refs

    assert {:error, cs} =
             Draft.put(draft, %{name: "fe-dev", mcp_servers: ["missing"]}, ctx.alice_scope, "ai")

    assert cs.errors[:mcp_servers]

    assert {:error, cs} =
             Draft.put(
               draft,
               %{name: "fe-dev", mcp_servers: [%{"command" => "curl"}]},
               ctx.alice_scope,
               "ai"
             )

    assert cs.errors[:mcp_servers]
    assert {:ok, _} = McpServers.update(ctx.alice_scope, d.id, %{name: "renamed"})
    assert {:error, cs} = Draft.create_attrs(entry, ctx.alice_scope)
    assert cs.errors[:mcp_servers]
    assert inspect(cs.errors) =~ "renamed"
    refute inspect(McpServers.design_options(ctx.alice.id)) =~ "PRIVATE_ARG"
  end

  defp definition(scope, name) do
    {:ok, definition} =
      McpServers.create(scope, %{
        name: name,
        config: %{"command" => "npx", "args" => ["EDIT_MCP_SECRET_CANARY"]}
      })

    definition
  end

  defp edit_ready(ctx, scope) do
    %{id: id} = start_edit!(scope, "fe-dev")
    end_and_settle!(run_turn!(ctx, id), :succeeded, summary: "ok")
    id
  end

  defp patch(scope, id, attrs) do
    AgentDesigns.put_agent(scope, id, design!(id).draft_version, Map.put(attrs, "name", "fe-dev"))
  end

  defp confirm(scope, id), do: AgentDesigns.confirm(scope, id, design!(id).draft_version)

  test "edit baselines preserve references, compare names, revert and write only changed references" do
    ctx = edit_fixture()
    old = definition(ctx.alice_scope, "existing")
    new = definition(ctx.alice_scope, "playwright")
    {:ok, _} = Agents.update(ctx.alice_scope, "fe-dev", %{mcp_server_ids: [old.id]})
    id = edit_ready(ctx, ctx.alice_scope)
    assert design!(id).baseline["agent"]["mcp_servers"] == ["existing"]
    assert {:ok, %{changes: []}} = AgentDesigns.get(ctx.alice_scope, id)
    assert {:ok, _} = patch(ctx.alice_scope, id, %{"mcp_servers" => ["existing", "playwright"]})

    assert {:ok,
            %{
              changes: [
                %{field: "mcp_servers", from: ["existing"], to: ["existing", "playwright"]}
              ]
            }} = AgentDesigns.get(ctx.alice_scope, id)

    assert {:ok, _, _} = Edit.revert(design!(id), "agent", "mcp_servers")
    assert {:ok, _} = confirm(ctx.alice_scope, id)

    assert Enum.map(McpServers.references([ctx.fe_dev.id])[ctx.fe_dev.id], & &1.id) == [
             old.id,
             new.id
           ]

    id = edit_ready(ctx, ctx.alice_scope)
    assert {:ok, _} = patch(ctx.alice_scope, id, %{"description" => "Only description"})
    assert {:ok, _} = confirm(ctx.alice_scope, id)

    assert Enum.map(McpServers.references([ctx.fe_dev.id])[ctx.fe_dev.id], & &1.id) == [
             old.id,
             new.id
           ]

    id = edit_ready(ctx, ctx.alice_scope)
    assert {:ok, _} = patch(ctx.alice_scope, id, %{"mcp_servers" => []})
    assert {:ok, _} = confirm(ctx.alice_scope, id)
    refute Map.has_key?(McpServers.references([ctx.fe_dev.id]), ctx.fe_dev.id)
  end

  test "editing rejects non-owned, missing, over-limit and executable entries without changing the draft" do
    ctx = edit_fixture()
    definition(ctx.alice_scope, "owned")
    definition(ctx.carol_scope, "foreign")
    id = edit_ready(ctx, ctx.alice_scope)

    for names <- [["foreign"], ["missing"], List.duplicate("owned", 17), [%{"command" => "curl"}]] do
      assert {:error, cs} = patch(ctx.alice_scope, id, %{"mcp_servers" => names})
      assert cs.errors[:mcp_servers]
      assert design!(id).draft_version == 0
    end
  end

  test "deleted or renamed edit references return field errors at confirmation and leave configuration unchanged" do
    for action <- [:delete, :rename] do
      ctx = edit_fixture()
      d = definition(ctx.alice_scope, "playwright")
      id = edit_ready(ctx, ctx.alice_scope)

      assert {:ok, _} =
               patch(ctx.alice_scope, id, %{
                 "mcp_servers" => ["playwright"],
                 "description" => "Not applied"
               })

      case action do
        :delete -> assert {:ok, :deleted} = McpServers.delete(ctx.alice_scope, d.id)
        :rename -> assert {:ok, _} = McpServers.update(ctx.alice_scope, d.id, %{name: "new-name"})
      end

      assert {:error, {:invalid, %{"fe-dev" => cs}}} = confirm(ctx.alice_scope, id)
      assert cs.errors[:mcp_servers]
      if action == :rename, do: assert(inspect(cs.errors) =~ "new-name")
      assert profile(ctx.fe_dev).description == "Builds the web UI"
      assert design!(id).status == :open
    end
  end

  test "admin edit exposes current reference names but no selectable definitions and cannot change them" do
    ctx = edit_fixture()
    d = definition(ctx.alice_scope, "owner-definition")
    definition(ctx.carol_scope, "ADMIN_PRIVATE_DEFINITION")
    {:ok, _} = Agents.update(ctx.alice_scope, "fe-dev", %{mcp_server_ids: [d.id]})
    %{id: id} = start_edit!(ctx.carol_scope, "fe-dev")
    {scope, _} = design_run_scope!(ctx, id)
    assert {:ok, view} = AgentDesigns.describe(scope)
    assert "mcp_servers" in view.readonly
    assert view.draft["agents"] |> hd() |> Map.fetch!("mcp_servers") == ["owner-definition"]
    refute Map.has_key?(view.options, :mcp_servers)
    refute inspect(view) =~ "EDIT_MCP_SECRET_CANARY"
    refute inspect(view) =~ "ADMIN_PRIVATE_DEFINITION"

    assert {:error, {:invalid_agent, "fe-dev", cs}} =
             AgentDesigns.propose_agent(scope, %{"name" => "fe-dev", "mcp_servers" => []})

    assert cs.errors[:mcp_servers]
    end_and_settle!(run_turn!(ctx, id), :succeeded, summary: "ok")
    assert {:error, cs} = patch(ctx.carol_scope, id, %{"mcp_servers" => []})
    assert cs.errors[:mcp_servers]
    assert {:ok, _} = patch(ctx.carol_scope, id, %{"description" => "Admin description"})
    assert {:ok, _} = confirm(ctx.carol_scope, id)
    assert [%{id: ref_id}] = McpServers.references([ctx.fe_dev.id])[ctx.fe_dev.id]
    assert ref_id == d.id
  end

  test "owner edit prompt offers only safe definition summaries and helper changes reference names" do
    ctx = edit_fixture()
    definition(ctx.alice_scope, "playwright")
    %{id: id} = start_edit!(ctx.alice_scope, "fe-dev")
    prompt = Prompt.for_run(current_run!(id))
    assert prompt =~ "playwright (stdio, npx)"
    refute prompt =~ "EDIT_MCP_SECRET_CANARY"
    {scope, _} = design_run_scope!(ctx, id)

    assert {:ok, %{agent: %{"mcp_servers" => ["playwright"]}}} =
             AgentDesigns.propose_agent(scope, %{
               "name" => "fe-dev",
               "mcp_servers" => ["playwright"]
             })

    assert {:ok, view} = AgentDesigns.describe(scope)
    assert [%{name: "playwright", type: "stdio", program: "npx"}] = view.options.mcp_servers
    refute inspect(view) =~ "EDIT_MCP_SECRET_CANARY"
  end

  test "changed references rebaseline before confirmation and conflict can be explicitly resolved" do
    ctx = edit_fixture()
    old = definition(ctx.alice_scope, "old")
    new = definition(ctx.alice_scope, "new")
    concurrent = definition(ctx.alice_scope, "concurrent")
    {:ok, _} = Agents.update(ctx.alice_scope, "fe-dev", %{mcp_server_ids: [old.id]})
    id = edit_ready(ctx, ctx.alice_scope)
    assert {:ok, _} = patch(ctx.alice_scope, id, %{"mcp_servers" => ["new"]})
    {:ok, _} = Agents.update(ctx.alice_scope, "fe-dev", %{mcp_server_ids: [concurrent.id]})
    assert {:error, {:baseline_changed, ["mcp_servers"]}} = confirm(ctx.alice_scope, id)
    assert design!(id).baseline["agent"]["mcp_servers"] == ["concurrent"]
    assert design!(id).draft["agents"] |> hd() |> Map.fetch!("conflicts") == ["mcp_servers"]
    assert {:ok, _} = patch(ctx.alice_scope, id, %{"mcp_servers" => ["new"]})
    assert {:ok, _} = confirm(ctx.alice_scope, id)
    assert [%{id: ref_id}] = McpServers.references([ctx.fe_dev.id])[ctx.fe_dev.id]
    assert ref_id == new.id
  end

  test "squad edit new agents confirm personal references" do
    ctx = edit_fixture()
    d = definition(ctx.alice_scope, "playwright")
    %{id: id} = start_edit!(ctx.alice_scope, "web-team")
    end_and_settle!(run_turn!(ctx, id), :succeeded, summary: "ok")

    assert {:ok, _} =
             AgentDesigns.put_agent(ctx.alice_scope, id, 0, %{
               "name" => "qa",
               "provider" => "claude",
               "instructions" => "Review UI",
               "mcp_servers" => ["playwright"]
             })

    assert {:ok, %{agents: [%{name: "qa", mcp_server_refs: [%{id: ref_id}]}]}} =
             confirm(ctx.alice_scope, id)

    assert ref_id == d.id
  end
end
