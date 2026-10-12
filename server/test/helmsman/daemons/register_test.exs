defmodule Helmsman.Daemons.RegisterTest do
  use Helmsman.DataCase, async: false

  import Helmsman.AccountsFixtures
  import Helmsman.WorkspacesFixtures
  import Helmsman.AgentsFixtures

  alias Helmsman.{CommittedData, Daemons, Events, Repo}
  alias Helmsman.Daemons.Runtime
  alias HelmsmanProtocol.{CLI, Machine, Report}

  setup do
    tag = System.unique_integer([:positive])

    {owner, alice, workspace, scope, alice_membership, daemon, epoch} =
      CommittedData.unboxed(fn ->
        owner = user_fixture(%{email: "register-owner-#{tag}@test.invalid"})
        alice = user_fixture(%{email: "register-alice-#{tag}@test.invalid"})
        workspace = workspace_fixture(owner)
        membership = member_fixture(workspace, alice, :member)
        scope = workspace_scope_fixture(owner, workspace)
        {daemon, _token} = daemon_fixture(alice, %{workspace_ids: [workspace.id]})

        {owner, alice, workspace, scope, membership, daemon, daemon.auth_epoch}
      end)

    on_exit(fn -> CommittedData.delete_user_data!([owner.id, alice.id]) end)

    %{
      owner: owner,
      alice: alice,
      workspace: workspace,
      scope: scope,
      alice_membership: alice_membership,
      daemon: daemon,
      epoch: epoch
    }
  end

  test "register returns online runtimes and notifies only when runtime state changes",
       %{daemon: daemon, epoch: epoch, workspace: workspace} do
    :ok = Events.subscribe(Events.topic(:workspace, workspace.id))
    report = report()

    assert {:ok, [runtime]} =
             CommittedData.unboxed(fn -> Daemons.register(daemon.id, epoch, report) end)

    assert runtime.workspace_id == workspace.id
    assert runtime.provider == :claude
    assert_receive {:runtimes_changed}, 1_000

    saved =
      CommittedData.unboxed(fn ->
        Repo.get_by!(Runtime, daemon_id: daemon.id, workspace_id: workspace.id)
      end)

    assert saved.status == "online"
    assert saved.cli_version == "3.2.1"
    assert saved.models == ["opus-4"]

    assert {:ok, [again]} =
             CommittedData.unboxed(fn -> Daemons.register(daemon.id, epoch, report) end)

    assert again.runtime_id == runtime.runtime_id
    refute_receive {:runtimes_changed}, 100
  end

  test "each CLI inventory field change notifies once and identical sync is silent",
       %{daemon: daemon, epoch: epoch, workspace: workspace} do
    :ok = Events.subscribe(Events.topic(:workspace, workspace.id))
    report = report()

    assert {:ok, [_]} =
             CommittedData.unboxed(fn -> Daemons.register(daemon.id, epoch, report) end)

    assert_receive {:runtimes_changed}

    Enum.reduce([version: "4.0.0", models: ["new-model"], efforts: ["low"]], report, fn
      {field, value}, report ->
        [cli] = report.clis
        report = %{report | clis: [Map.put(cli, field, value)]}

        assert {:ok, [_]} =
                 CommittedData.unboxed(fn -> Daemons.register(daemon.id, epoch, report) end)

        assert_receive {:runtimes_changed}
        refute_receive {:runtimes_changed}

        assert {:ok, [_]} =
                 CommittedData.unboxed(fn -> Daemons.register(daemon.id, epoch, report) end)

        refute_receive {:runtimes_changed}
        report
    end)
  end

  test "registration stops serving a workspace after its owner is demoted to viewer",
       %{
         daemon: daemon,
         epoch: epoch,
         scope: owner_scope,
         alice_membership: membership,
         workspace: workspace
       } do
    assert {:ok, [_]} =
             CommittedData.unboxed(fn -> Daemons.register(daemon.id, epoch, report()) end)

    assert {:ok, _} =
             CommittedData.unboxed(fn ->
               Helmsman.Members.change_role(owner_scope, membership.id, :viewer)
             end)

    assert {:ok, []} =
             CommittedData.unboxed(fn -> Daemons.register(daemon.id, epoch, report()) end)

    runtime =
      CommittedData.unboxed(fn ->
        Repo.get_by!(Runtime, daemon_id: daemon.id, workspace_id: workspace.id)
      end)

    assert runtime.status == "offline"
  end

  test "register emits one runtime notification when a served workspace is no longer eligible",
       %{daemon: daemon, epoch: epoch, workspace: workspace, alice_membership: membership} do
    assert {:ok, [_]} =
             CommittedData.unboxed(fn -> Daemons.register(daemon.id, epoch, report()) end)

    # Simulate a concurrent role update whose cascade has not yet reached the
    # daemon rows; register itself must offline the runtime and notify once.
    CommittedData.unboxed(fn ->
      Repo.update_all(
        from(m in Helmsman.Workspaces.Membership, where: m.id == ^membership.id),
        set: [role: :viewer]
      )
    end)

    :ok = Events.subscribe(Events.topic(:workspace, workspace.id))

    assert {:ok, []} =
             CommittedData.unboxed(fn -> Daemons.register(daemon.id, epoch, report()) end)

    assert_receive {:runtimes_changed}, 1_000
    refute_receive {:runtimes_changed}, 100

    assert CommittedData.unboxed(fn ->
             Repo.get_by!(Runtime, daemon_id: daemon.id, workspace_id: workspace.id).status
           end) == "offline"
  end

  defp report do
    %Report.Join{
      protocol: HelmsmanProtocol.version(),
      machine: %Machine{os: "linux", arch: "x86_64", daemon_version: "0.9.0"},
      clis: [
        %CLI{
          provider: :claude,
          version: "3.2.1",
          models: ["opus-4"],
          efforts: ["high"],
          available: true
        }
      ],
      max_concurrency: 6,
      active_runs: []
    }
  end
end
