defmodule Helmsman.Runs.McpEnvClaimTest do
  use Helmsman.DataCase, async: true
  import Helmsman.RunsFixtures
  import Helmsman.AgentsFixtures
  alias Helmsman.{Agents, Dispatch, McpServers, Runs}
  alias Helmsman.Daemons.Daemon
  alias Helmsman.Runs.Run

  test "effective references gate old daemons, plain runs are still claimable" do
    ctx = dispatch_fixture()
    daemon = daemon_of(ctx.agent)

    Repo.update_all(from(d in Daemon, where: d.id == ^daemon.id),
      set: [protocol_version: HelmsmanProtocol.mcp_env_version() - 1]
    )

    {:ok, definition} =
      McpServers.create(ctx.alice_scope, %{
        name: "github",
        config: %{"command" => "npx", "env" => %{"TOKEN" => "${env:TOKEN}"}}
      })

    assert {:ok, _} =
             Agents.update(ctx.alice_scope, ctx.agent.name, %{mcp_server_ids: [definition.id]})

    plain =
      managed_agent_fixture(ctx.alice_scope, %{
        name: "plain",
        runtime_id: profile(ctx.agent).runtime_id
      })

    bound_run = run_fixture(ctx.agent)
    plain_run = run_fixture(agent_actor(ctx.workspace, plain.name))
    assert {:ok, availability} = Dispatch.availability(ctx.alice_scope)
    assert availability[ctx.agent.name].result == {:skipped, :daemon_outdated}

    assert {:ok, [%{run_id: id}]} =
             Runs.claim(
               %{daemon_ctx(daemon) | protocol: HelmsmanProtocol.mcp_env_version() - 1},
               "http://localhost"
             )

    assert id == plain_run.id
    assert Repo.get!(Run, bound_run.id).status == :queued

    assert {:ok, [%{run_id: id, agent: agent}]} =
             Runs.claim(
               %{daemon_ctx(daemon) | protocol: HelmsmanProtocol.mcp_env_version()},
               "http://localhost"
             )

    assert id == bound_run.id
    assert agent.extra_mcp_servers["github"]["env"]["TOKEN"] == "${env:TOKEN}"
  end

  test "legacy collisions remain claimable on old protocol, logged safely, summary marks shadowed" do
    ctx = dispatch_fixture()

    {:ok, definition} =
      McpServers.create(ctx.alice_scope, %{
        name: "personal",
        config: %{"command" => "npx", "auth" => "COLLISION_CANARY"}
      })

    {:ok, _} = Agents.update(ctx.alice_scope, ctx.agent.name, %{mcp_server_ids: [definition.id]})

    Repo.update!(
      Ecto.Changeset.change(profile(ctx.agent),
        extra_mcp_servers: %{"PERSONAL" => %{"command" => "uvx"}}
      )
    )

    run = run_fixture(ctx.agent)
    daemon = daemon_of(ctx.agent)

    log =
      ExUnit.CaptureLog.capture_log(
        [format: "$message $metadata", metadata: [:agent_id, :mcp_definition_name]],
        fn ->
          assert {:ok, [spec]} =
                   Runs.claim(
                     %{daemon_ctx(daemon) | protocol: HelmsmanProtocol.mcp_env_version() - 1},
                     "http://localhost"
                   )

          assert spec.run_id == run.id
          assert spec.agent.extra_mcp_servers == %{"PERSONAL" => %{"command" => "uvx"}}

          assert {:ok, wire} =
                   HelmsmanProtocol.Messages.encode_reply(
                     "claim",
                     %HelmsmanProtocol.Reply.Claim{runs: [spec]},
                     HelmsmanProtocol.mcp_env_version() - 1
                   )

          refute Map.has_key?(hd(wire["runs"])["agent"], "mcp_warnings")
        end
      )

    assert log =~ "Personal MCP definition shadowed"
    assert log =~ "mcp_definition_name=personal"
    refute log =~ "COLLISION_CANARY"
    assert {:ok, summaries} = McpServers.agent_summaries(ctx.alice_scope, ctx.agent)
    assert %{name: "personal", source: "personal", shadowed: true} in summaries
    refute inspect(summaries) =~ "COLLISION_CANARY"
    {_member, member_scope} = member_scope_fixture(ctx.workspace)
    assert {:ok, summaries} = McpServers.agent_summaries(member_scope, ctx.agent)
    refute Enum.any?(summaries, &Map.get(&1, :shadowed, false))
  end
end
