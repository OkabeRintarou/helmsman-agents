defmodule Helmsman.AgentsFixtures do
  @moduledoc "Reusable managed-agent, daemon and runtime fixtures."
  use Boundary, top_level?: true, check: [in: false, out: false]
  alias Helmsman.{Agents, Daemons, Repo}
  alias Helmsman.Daemons.{Daemon, DaemonWorkspace, Runtime}

  def daemon_fixture(user, attrs \\ %{}) do
    token = Daemons.new_token()

    daemon =
      struct!(
        Daemon,
        Map.merge(
          %{
            user_id: user.id,
            machine_id: "machine-#{System.unique_integer([:positive])}",
            name: "test-machine",
            os: "linux",
            arch: "x86_64",
            version: "0.1.0",
            protocol_version: HelmsmanProtocol.version(),
            token_hash: Daemons.hash(token),
            token_issued_at: Daemons.now(),
            last_seen_at: Daemons.now()
          },
          Map.drop(attrs, [:workspace_ids])
        )
      )
      |> Repo.insert!()

    for id <- Map.get(attrs, :workspace_ids, []) do
      Repo.insert!(%DaemonWorkspace{
        daemon_id: daemon.id,
        workspace_id: id,
        inserted_at: Daemons.now()
      })
    end

    {daemon, token}
  end

  def runtime_fixture(workspace, daemon, attrs \\ %{}) do
    Repo.insert!(
      struct!(
        Runtime,
        Map.merge(
          %{
            workspace_id: workspace.id,
            daemon_id: daemon.id,
            provider: "claude",
            cli_version: "2.0.0",
            models: [],
            efforts: [],
            status: "online"
          },
          attrs
        )
      )
    )
  end

  def managed_agent_fixture(scope, attrs \\ %{}) do
    attrs =
      if Map.has_key?(attrs, :runtime_id) do
        attrs
      else
        {daemon, _token} = daemon_fixture(scope.user, %{workspace_ids: [scope.workspace.id]})

        runtime =
          runtime_fixture(scope.workspace, daemon, %{
            provider: Map.get(attrs, :provider, "claude")
          })

        Map.put(attrs, :runtime_id, runtime.id)
      end

    {:ok, agent} =
      Agents.create(
        scope,
        Map.merge(
          %{name: "agent-#{System.unique_integer([:positive])}", provider: "claude"},
          attrs
        )
      )

    agent
  end
end
