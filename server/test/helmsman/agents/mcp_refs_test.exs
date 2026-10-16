defmodule Helmsman.Agents.McpRefsTest do
  use Helmsman.DataCase, async: true
  import Helmsman.RunsFixtures
  alias Helmsman.{Agents, McpServers, Repo}
  alias Helmsman.McpServers.Ref

  setup do
    dispatch_fixture(%{access: "workspace"})
  end

  test "owner binds, current definitions merge, deletion is guarded and rename conflicts", ctx do
    assert {:ok, d} =
             McpServers.create(ctx.alice_scope, %{name: "github", config: %{"command" => "npx"}})

    assert {:ok, view} =
             Agents.update(ctx.alice_scope, ctx.agent.name, %{
               mcp_server_ids: [d.id],
               extra_mcp_servers: %{"docs" => %{"command" => "uvx"}}
             })

    assert [%{name: "github", source: "personal"}] = view.mcp_server_refs
    assert {:ok, profile} = Agents.execution_config(ctx.agent.id)
    assert Map.keys(profile.extra_mcp_servers) |> Enum.sort() == ~w(docs github)
    assert {:error, {:in_use, [_]}} = McpServers.delete(ctx.alice_scope, d.id)
    assert {:error, cs} = McpServers.update(ctx.alice_scope, d.id, %{name: "docs"})
    assert cs.errors[:name]

    assert {:ok, _} =
             McpServers.update(ctx.alice_scope, d.id, %{
               name: "renamed",
               config: %{"command" => "docker"}
             })

    assert {:ok, profile} = Agents.execution_config(ctx.agent.id)
    assert profile.extra_mcp_servers["renamed"]["command"] == "docker"
    assert {:ok, _} = Agents.update(ctx.alice_scope, ctx.agent.name, %{mcp_server_ids: []})
    assert {:ok, :deleted} = McpServers.delete(ctx.alice_scope, d.id)
    assert Repo.aggregate(Ref, :count) == 0
  end

  test "foreign definitions, duplicate own names and more than 16 are rejected", ctx do
    {_user, other} = member_scope_fixture(ctx.workspace)
    {:ok, d} = McpServers.create(other, %{name: "docs", config: %{"command" => "npx"}})

    assert {:error, cs} =
             Agents.update(ctx.alice_scope, ctx.agent.name, %{mcp_server_ids: [d.id]})

    assert cs.errors[:mcp_server_ids]

    ids =
      for i <- 1..17 do
        {:ok, d} =
          McpServers.create(ctx.alice_scope, %{name: "docs#{i}", config: %{"command" => "npx"}})

        d.id
      end

    assert {:error, cs} = Agents.update(ctx.alice_scope, ctx.agent.name, %{mcp_server_ids: ids})
    assert cs.errors[:mcp_server_ids]

    assert {:error, cs} =
             Agents.update(ctx.alice_scope, ctx.agent.name, %{
               mcp_server_ids: [hd(ids)],
               extra_mcp_servers: %{"DOCS1" => %{"command" => "uvx"}}
             })

    assert cs.errors[:mcp_server_ids]
  end

  test "legacy collisions prefer own entry; archived references block rename but permit delete",
       ctx do
    {:ok, definition} =
      McpServers.create(ctx.alice_scope, %{name: "personal", config: %{"command" => "npx"}})

    {:ok, _} = Agents.update(ctx.alice_scope, ctx.agent.name, %{mcp_server_ids: [definition.id]})
    profile = profile(ctx.agent)

    Repo.update!(
      Ecto.Changeset.change(profile,
        extra_mcp_servers: %{
          "PERSONAL" => %{"command" => "uvx"},
          "next" => %{"command" => "docker"}
        },
        archived_at: DateTime.utc_now(:second)
      )
    )

    {config, warnings} =
      McpServers.effective(Repo.get_by!(Helmsman.Agents.AgentProfile, actor_id: ctx.agent.id))

    assert config == %{"PERSONAL" => %{"command" => "uvx"}, "next" => %{"command" => "docker"}}
    assert [warning] = warnings
    assert warning =~ "personal"
    assert {:error, cs} = McpServers.update(ctx.alice_scope, definition.id, %{name: "next"})
    assert cs.errors[:name]
    assert {:ok, :deleted} = McpServers.delete(ctx.alice_scope, definition.id)
    refute Repo.exists?(from r in Ref, where: r.server_id == ^definition.id)
  end
end
