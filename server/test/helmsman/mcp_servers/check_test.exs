defmodule Helmsman.McpServers.CheckTest do
  use Helmsman.DataCase, async: true
  import Helmsman.RunsFixtures
  import ExUnit.CaptureLog
  alias Helmsman.{Agents, Events}
  alias Helmsman.McpServers.Check
  alias HelmsmanProtocol.{McpCheckResult, Report}

  setup do
    ctx = dispatch_fixture()
    daemon = daemon_of(ctx.agent)
    Events.subscribe(Events.topic(:daemon, daemon.id))
    Map.put(ctx, :daemon, daemon)
  end

  test "owner request uses Agent environment, result is private, throttled and has no secret logs",
       ctx do
    assert {:ok, _} =
             Agents.update(ctx.alice_scope, ctx.agent.name, %{
               env: %{"TOKEN" => "CANARY_AGENT_ENV"},
               extra_mcp_servers: %{
                 "docs" => %{
                   "command" => "${env:BIN}",
                   "args" => ["PRIVATE_ARG"],
                   "env" => %{"TOKEN" => "${env:TOKEN}"}
                 }
               }
             })

    log =
      capture_log(fn ->
        assert {:ok, id} = Check.request(ctx.alice_scope, ctx.agent.name)
        assert_receive {:mcp_check_request, push}
        assert push.agent_env == %{"TOKEN" => "CANARY_AGENT_ENV"}
        assert [%{command: "${env:BIN}", env_refs: refs}] = push.servers
        assert Enum.sort(refs) == ~w(BIN TOKEN)
        refute inspect(push.servers) =~ "PRIVATE_ARG"
        refute inspect(push) =~ "CANARY_AGENT_ENV"

        report = %Report.McpCheckResult{
          check_id: id,
          results: [
            %McpCheckResult{name: "docs", command_found: :no, missing_env: ["BIN"], dropped: nil}
          ]
        }

        assert {:error, :not_found} = Check.deliver(ctx.daemon.id + 1, report)
        assert :ok = Check.deliver(ctx.daemon.id, report)
        assert_receive {:mcp_check_result, ^id, {:ok, [_]}}
        assert {:error, :rate_limited} = Check.request(ctx.alice_scope, ctx.agent.name)
        assert {:error, :not_found} = Check.deliver(ctx.daemon.id, report)
      end)

    refute log =~ "CANARY_AGENT_ENV"
    assert {:error, :forbidden} = Check.request(%{ctx.alice_scope | via: :mcp}, ctx.agent.name)

    assert {:error, :not_found} =
             Check.request(elem(member_scope_fixture(ctx.workspace), 1), ctx.agent.name)
  end

  test "disabled runtime and malformed commands are rejected without broadcast", ctx do
    runtime = profile(ctx.agent).runtime_id

    Repo.update_all(from(r in Helmsman.Daemons.Runtime, where: r.id == ^runtime),
      set: [disabled_at: DateTime.utc_now(:second)]
    )

    assert {:error, :runtime_disabled} = Check.request(ctx.alice_scope, ctx.agent.name)

    Repo.update_all(from(r in Helmsman.Daemons.Runtime, where: r.id == ^runtime),
      set: [disabled_at: nil]
    )

    Repo.update!(
      Ecto.Changeset.change(profile(ctx.agent),
        extra_mcp_servers: %{"bad" => %{"command" => ["MALFORMED_CANARY"]}}
      )
    )

    assert {:error, :invalid_configuration} = Check.request(ctx.alice_scope, ctx.agent.name)
    refute_received {:mcp_check_request, _}
  end

  test "timeout and direct runtime reasons", ctx do
    assert {:ok, id} = Check.request(ctx.alice_scope, ctx.agent.name)
    send(Check, {:timeout, id})
    assert_receive {:mcp_check_result, ^id, {:error, :timeout}}
    runtime = profile(ctx.agent).runtime_id

    Repo.update_all(from(r in Helmsman.Daemons.Runtime, where: r.id == ^runtime),
      set: [status: "offline"]
    )

    assert {:error, :daemon_offline} = Check.request(ctx.alice_scope, ctx.agent.name)

    Repo.update_all(from(r in Helmsman.Daemons.Runtime, where: r.id == ^runtime),
      set: [status: "online"]
    )

    Repo.update_all(from(d in Helmsman.Daemons.Daemon, where: d.id == ^ctx.daemon.id),
      set: [protocol_version: HelmsmanProtocol.mcp_env_version() - 1]
    )

    assert {:error, :daemon_outdated} = Check.request(ctx.alice_scope, ctx.agent.name)
    assert {:ok, _} = Agents.update(ctx.alice_scope, ctx.agent.name, %{runtime_id: nil})
    assert {:error, :no_runtime} = Check.request(ctx.alice_scope, ctx.agent.name)
  end
end
