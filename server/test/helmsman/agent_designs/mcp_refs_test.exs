defmodule Helmsman.AgentDesigns.McpRefsTest do
  use Helmsman.DataCase, async: true
  import Helmsman.AgentDesignsFixtures
  import Helmsman.RunsFixtures
  alias Helmsman.AgentDesigns
  alias Helmsman.AgentDesigns.{Draft, Prompt}
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
end
