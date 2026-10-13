defmodule Helmsman.E2E.CodexProviderAuthTest do
  # #52 acceptance 4.2: an unbound Codex agent with an empty selected home
  # fails before the daemon starts `codex app-server`.
  use ExUnit.Case, async: false

  @moduletag :e2e
  if :os.type() != {:unix, :linux} do
    @moduletag skip: "daemon E2E tests require Linux"
  end

  @moduletag timeout: 180_000

  import Helmsman.AccountsFixtures
  import Helmsman.AgentsFixtures
  import Helmsman.ProjectsFixtures
  import Helmsman.RunsFixtures
  import Helmsman.WorkspacesFixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias Helmsman.{CommittedData, DaemonE2E, Repo}
  alias Helmsman.Daemons.Runtime
  alias Helmsman.Runs.Run

  setup do
    :ok = Sandbox.mode(Repo, :auto)
    on_exit(fn -> Sandbox.mode(Repo, :manual) end)

    tag = Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
    home = Path.join(System.tmp_dir!(), "helmsman-codex-provider-auth-#{tag}")
    bin = Path.join(home, "bin")
    File.mkdir_p!(bin)
    on_exit(fn -> File.rm_rf!(home) end)

    ctx =
      CommittedData.unboxed(fn ->
        owner = user_fixture(%{email: "codex-provider-auth-#{tag}@test.invalid"})
        workspace = workspace_fixture(owner, %{slug: "codex-provider-auth-#{tag}"})
        scope = workspace_scope_fixture(owner, workspace)
        project = project_fixture(scope)
        {daemon, token} = daemon_fixture(owner, %{workspace_ids: [workspace.id]})

        %{
          owner: owner,
          workspace: workspace,
          scope: scope,
          project: project,
          daemon: daemon,
          token: token
        }
      end)

    on_exit(fn -> CommittedData.delete_user_data!([ctx.owner.id]) end)
    Map.merge(ctx, %{home: home, bin: bin})
  end

  test "unbound agent with an empty selected Codex home fails before app-server launch", ctx do
    endpoint_url = DaemonE2E.start_endpoint()
    daemon_home = Path.join(ctx.home, "daemon-home")
    codex_home = Path.join(ctx.home, "empty-codex-home")
    marker = Path.join(ctx.home, "app-server-started")
    File.mkdir_p!(codex_home)

    DaemonE2E.write_credentials(daemon_home, endpoint_url, ctx.daemon.id, ctx.token)
    daemon_config = Path.join(daemon_home, "config.toml")

    File.write!(
      daemon_config,
      File.read!(daemon_config) <> "\n[codex]\nhome = #{Jason.encode!(codex_home)}\n"
    )

    install_codex_cli(ctx.bin)

    port =
      DaemonE2E.start_provider_daemon(daemon_home, [
        {~c"PATH", String.to_charlist(ctx.bin <> ":" <> System.fetch_env!("PATH"))},
        {~c"HOME", String.to_charlist(daemon_home)},
        {~c"CODEX_ACCEPTANCE_MARKER", String.to_charlist(marker)}
      ])

    runtime =
      DaemonE2E.wait_until(port, "Codex runtime online", fn ->
        case Repo.get_by(Runtime,
               daemon_id: ctx.daemon.id,
               workspace_id: ctx.workspace.id,
               provider: "codex"
             ) do
          %Runtime{status: "online"} = online -> online
          _ -> nil
        end
      end)

    {agent, run} =
      CommittedData.unboxed(fn ->
        managed_agent_fixture(ctx.scope, %{
          name: "keel/codex-provider-auth",
          provider: "codex",
          runtime_id: runtime.id
        })

        agent = agent_actor(ctx.workspace, "keel/codex-provider-auth")
        assert is_nil(profile(agent).provider_account_id)

        task =
          task_fixture(ctx.scope, ctx.project.key, %{
            assignee: agent.name,
            title: "Check Codex provider setup"
          })

        [run] = runs_of(task.id)
        {agent, run}
      end)

    assert %Run{status: :failed, failure_reason: :provider_auth, error: error} =
             DaemonE2E.wait_until(port, "provider_auth failure", fn ->
               current = Repo.get!(Run, run.id)
               if current.status in Run.ended_statuses(), do: current
             end)

    assert error =~ "Codex has no model provider"
    assert error =~ codex_home
    assert error =~ "codex login"
    assert error =~ "config.toml"
    assert File.dir?(codex_home)
    refute File.exists?(marker)

    # Keep the binding invariant explicit for this acceptance case.
    assert profile(agent).provider_account_id == nil
  end

  defp install_codex_cli(bin) do
    path = Path.join(bin, "codex")

    File.write!(path, """
    #!/bin/sh
    if [ "$1" = "--version" ]; then
      echo "codex-cli 0.162.1"
      exit 0
    fi
    if [ "$1" = "login" ] && [ "$2" = "status" ]; then
      exit 1
    fi
    if [ "$1" = "app-server" ]; then
      printf started > "$CODEX_ACCEPTANCE_MARKER"
      exit 97
    fi
    exit 2
    """)

    File.chmod!(path, 0o700)
    path
  end
end
