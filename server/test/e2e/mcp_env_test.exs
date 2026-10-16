defmodule Helmsman.E2E.McpEnvTest do
  use ExUnit.Case, async: false
  @moduletag :e2e
  @moduletag timeout: 300_000
  import Helmsman.AccountsFixtures
  import Helmsman.WorkspacesFixtures
  import Helmsman.AgentsFixtures
  import Helmsman.RunsFixtures
  alias Ecto.Adapters.SQL.Sandbox
  alias Helmsman.{CommittedData, DaemonE2E, McpServers, Repo, Runs}
  alias Helmsman.Daemons.Runtime
  alias Helmsman.Runs.Run

  setup do
    Sandbox.mode(Repo, :auto)
    on_exit(fn -> Sandbox.mode(Repo, :manual) end)
    tag = Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
    home = Path.join(System.tmp_dir!(), "mcp-env-e2e-#{tag}")
    bin = Path.join(home, "bin")
    File.mkdir_p!(bin)
    File.ln!(Path.expand("../support/fake_cli/mcp-env-claude", __DIR__), Path.join(bin, "claude"))
    on_exit(fn -> File.rm_rf!(home) end)

    ctx =
      CommittedData.unboxed(fn ->
        user = user_fixture()
        ws = workspace_fixture(user)
        scope = workspace_scope_fixture(user, ws)
        {daemon, token} = daemon_fixture(user, %{workspace_ids: [ws.id]})
        runtime = runtime_fixture(ws, daemon)

        {:ok, definition} =
          McpServers.create(scope, %{
            name: "personal",
            config: %{"command" => "npx", "env" => %{"TOKEN" => "${env:MCP_E2E_CANARY}"}}
          })

        agent =
          managed_agent_fixture(scope, %{
            name: "mcp-e2e",
            runtime_id: runtime.id,
            mcp_server_ids: [definition.id],
            extra_mcp_servers: %{
              "own" => %{
                "type" => "http",
                "url" => "https://a.test",
                "headers" => %{"Authorization" => "Bearer ${env:MCP_E2E_CANARY}"}
              },
              "missing" => %{"command" => "${env:MCP_E2E_MISSING}"}
            }
          })

        %{user: user, scope: scope, daemon: daemon, token: token, runtime: runtime, agent: agent}
      end)

    on_exit(fn -> CommittedData.delete_user_data!([ctx.user.id]) end)

    Map.merge(ctx, %{
      home: home,
      bin: bin,
      url: DaemonE2E.start_endpoint(),
      canary: "CANARY_LOCAL_ONLY_#{tag}"
    })
  end

  test "real daemon expands owned and personal config, emits no values and completes a local check",
       ctx do
    daemon_home = Path.join(ctx.home, "daemon")
    DaemonE2E.write_credentials(daemon_home, ctx.url, ctx.daemon.id, ctx.token)

    daemon =
      DaemonE2E.start_provider_daemon(daemon_home, [
        {~c"PATH", String.to_charlist(ctx.bin <> ":" <> System.get_env("PATH", ""))},
        {~c"MCP_E2E_CANARY", String.to_charlist(ctx.canary)}
      ])

    DaemonE2E.wait_until(daemon, "runtime online", fn ->
      Repo.get!(Runtime, ctx.runtime.id).status == "online"
    end)

    run = run_fixture(agent_actor(ctx.scope.workspace, ctx.agent.name))

    DaemonE2E.wait_until(daemon, "MCP run succeeds", fn ->
      Repo.get!(Run, run.id).status == :succeeded
    end)

    {:ok, events} = Runs.list_events(ctx.scope, run.id)
    assert inspect(events) =~ "MCP local expansion checked"
    assert inspect(events) =~ "MCP_E2E_MISSING"
    refute inspect(events) =~ ctx.canary
    profile = Repo.get_by!(Helmsman.Agents.AgentProfile, actor_id: ctx.agent.actor_id)
    refute inspect(profile.extra_mcp_servers) =~ ctx.canary
    assert {:ok, id} = McpServers.Check.request(ctx.scope, ctx.agent.name)
    assert_receive {:mcp_check_result, ^id, {:ok, results}}, 12_000
    assert Enum.find(results, &(&1.name == "personal")).missing_env == []
    assert Enum.find(results, &(&1.name == "missing")).missing_env == ["MCP_E2E_MISSING"]
    refute inspect(results) =~ ctx.canary
    refute DaemonE2E.output(daemon) =~ ctx.canary
  end
end
