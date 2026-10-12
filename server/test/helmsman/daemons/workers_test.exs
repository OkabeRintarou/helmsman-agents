defmodule Helmsman.Daemons.WorkersTest do
  use Helmsman.DataCase, async: false
  use Oban.Testing, repo: Helmsman.Repo

  import Helmsman.AccountsFixtures
  import Helmsman.AgentsFixtures
  import Helmsman.WorkspacesFixtures

  alias Helmsman.Daemons.{Daemon, DeviceCode, Runtime}
  alias Helmsman.Daemons.Workers.{MarkOffline, PruneDeviceCodes}
  alias Helmsman.{Events, Repo}

  @clock ~U[2026-10-12 12:00:00Z]

  setup do
    previous_clock = Application.get_env(:helmsman, :daemon_clock)
    Application.put_env(:helmsman, :daemon_clock, fn -> @clock end)

    on_exit(fn ->
      case previous_clock do
        nil -> Application.delete_env(:helmsman, :daemon_clock)
        clock -> Application.put_env(:helmsman, :daemon_clock, clock)
      end
    end)

    user = user_fixture()
    workspace = workspace_fixture(user)
    scope = workspace_scope_fixture(user, workspace)
    {daemon, _token} = daemon_fixture(user, %{workspace_ids: [workspace.id]})
    runtime = runtime_fixture(workspace, daemon)

    %{user: user, workspace: workspace, scope: scope, daemon: daemon, runtime: runtime}
  end

  test "MarkOffline respects the two minute boundary and notifies after a stale runtime changes",
       %{workspace: workspace, daemon: daemon, runtime: runtime} do
    Events.subscribe(Events.topic(:workspace, workspace.id))
    Events.subscribe(Events.topic(:daemon, daemon.id))

    Repo.update!(Ecto.Changeset.change(daemon, last_seen_at: DateTime.add(@clock, -120)))
    assert :ok = perform_job(MarkOffline, %{})
    assert Repo.get!(Runtime, runtime.id).status == "online"
    refute_received {:runtimes_changed}
    refute_received {:daemon_config_changed}

    daemon = Repo.get!(Daemon, daemon.id)
    Repo.update!(Ecto.Changeset.change(daemon, last_seen_at: DateTime.add(@clock, -121)))

    assert :ok = perform_job(MarkOffline, %{})
    assert Repo.get!(Runtime, runtime.id).status == "offline"
    assert_received {:runtimes_changed}
    assert_received {:daemon_config_changed}
    refute_received {:runtimes_changed}
    refute_received {:daemon_config_changed}
  end

  test "MarkOffline immediately takes a revoked daemon's online runtimes offline",
       %{workspace: workspace, daemon: daemon, runtime: runtime} do
    Events.subscribe(Events.topic(:workspace, workspace.id))
    Events.subscribe(Events.topic(:daemon, daemon.id))

    Repo.update!(Ecto.Changeset.change(daemon, revoked_at: @clock))

    assert :ok = perform_job(MarkOffline, %{})
    assert Repo.get!(Runtime, runtime.id).status == "offline"
    assert_received {:runtimes_changed}
    assert_received {:daemon_config_changed}
  end

  test "PruneDeviceCodes deletes codes expired for more than a day and keeps the cutoff",
       %{user: user} do
    too_old = insert_device_code(user, DateTime.add(@clock, -86_401), "old")
    at_cutoff = insert_device_code(user, DateTime.add(@clock, -86_400), "cutoff")
    recent = insert_device_code(user, DateTime.add(@clock, -86_399), "recent")

    assert :ok = perform_job(PruneDeviceCodes, %{})

    assert Repo.get(DeviceCode, too_old.id) == nil
    assert Repo.get!(DeviceCode, at_cutoff.id).id == at_cutoff.id
    assert Repo.get!(DeviceCode, recent.id).id == recent.id
  end

  defp insert_device_code(user, expires_at, suffix) do
    Repo.insert!(%DeviceCode{
      device_code_hash: :crypto.hash(:sha256, suffix),
      user_code: "USED-#{String.upcase(suffix)}",
      machine: %{"machine_id" => "machine-#{suffix}"},
      protocol_version: HelmsmanProtocol.version(),
      user_id: user.id,
      status: "used",
      expires_at: expires_at
    })
  end
end
