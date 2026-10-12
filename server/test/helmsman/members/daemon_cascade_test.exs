defmodule Helmsman.Members.DaemonCascadeTest do
  use Helmsman.DataCase, async: false

  import Helmsman.AccountsFixtures
  import Helmsman.WorkspacesFixtures
  import Helmsman.AgentsFixtures

  alias Helmsman.{CommittedData, Daemons, Events, Repo}
  alias Helmsman.Daemons.{DaemonWorkspace, Runtime}
  alias Helmsman.Members

  setup do
    tag = System.unique_integer([:positive])

    {acme_owner, beta_owner, alice, acme, beta, acme_scope, alice_acme_scope, acme_membership,
     daemon, epoch, acme_runtime, beta_runtime} =
      CommittedData.unboxed(fn ->
        acme_owner = user_fixture(%{email: "acme-owner-#{tag}@test.invalid"})
        beta_owner = user_fixture(%{email: "beta-owner-#{tag}@test.invalid"})
        alice = user_fixture(%{email: "daemon-member-#{tag}@test.invalid"})
        acme = workspace_fixture(acme_owner)
        beta = workspace_fixture(beta_owner)
        acme_membership = member_fixture(acme, alice, :member)
        member_fixture(beta, alice, :member)
        acme_scope = workspace_scope_fixture(acme_owner, acme)
        alice_acme_scope = workspace_scope_fixture(alice, acme)
        {daemon, _token} = daemon_fixture(alice, %{workspace_ids: [acme.id, beta.id]})
        acme_runtime = runtime_fixture(acme, daemon)
        beta_runtime = runtime_fixture(beta, daemon)

        {acme_owner, beta_owner, alice, acme, beta, acme_scope, alice_acme_scope, acme_membership,
         daemon, daemon.auth_epoch, acme_runtime, beta_runtime}
      end)

    on_exit(fn -> CommittedData.delete_user_data!([acme_owner.id, beta_owner.id, alice.id]) end)

    %{
      acme_owner: acme_owner,
      beta_owner: beta_owner,
      alice: alice,
      acme: acme,
      beta: beta,
      acme_scope: acme_scope,
      alice_acme_scope: alice_acme_scope,
      acme_membership: acme_membership,
      daemon: daemon,
      epoch: epoch,
      acme_runtime: acme_runtime,
      beta_runtime: beta_runtime
    }
  end

  test "removing a member stops only that workspace and updates service links",
       %{
         acme_scope: scope,
         acme_membership: membership,
         daemon: daemon,
         epoch: epoch,
         acme: acme,
         beta: beta,
         acme_runtime: acme_runtime,
         beta_runtime: beta_runtime
       } do
    :ok = Events.subscribe(Events.topic(:workspace, acme.id))
    :ok = Events.subscribe(Events.topic(:daemon, daemon.id))

    assert {:ok, _} = CommittedData.unboxed(fn -> Members.remove(scope, membership.id) end)

    assert_receive {:runtimes_changed}, 1_000
    assert_receive {:daemon_config_changed}, 1_000

    assert CommittedData.unboxed(fn -> Repo.get(Runtime, acme_runtime.id).status end) == "offline"
    assert CommittedData.unboxed(fn -> Repo.get(Runtime, beta_runtime.id).status end) == "online"

    serviced =
      CommittedData.unboxed(fn ->
        Repo.all(
          from link in DaemonWorkspace,
            where: link.daemon_id == ^daemon.id,
            select: link.workspace_id,
            order_by: link.workspace_id
        )
      end)

    assert serviced == [beta.id]

    assert {:ok, runtimes} =
             CommittedData.unboxed(fn -> Daemons.register(daemon.id, epoch, report()) end)

    assert Enum.map(runtimes, & &1.workspace_id) == [beta.id]
    refute Enum.any?(runtimes, &(&1.workspace_id == acme.id))
  end

  test "leaving a workspace applies the same daemon service cascade",
       %{
         alice_acme_scope: scope,
         daemon: daemon,
         acme: acme,
         beta: beta,
         acme_runtime: acme_runtime,
         beta_runtime: beta_runtime
       } do
    :ok = Events.subscribe(Events.topic(:workspace, acme.id))
    :ok = Events.subscribe(Events.topic(:daemon, daemon.id))

    assert {:ok, _} = CommittedData.unboxed(fn -> Members.leave(scope) end)
    assert_receive {:runtimes_changed}, 1_000
    assert_receive {:daemon_config_changed}, 1_000

    assert CommittedData.unboxed(fn -> Repo.get(Runtime, acme_runtime.id).status end) == "offline"
    assert CommittedData.unboxed(fn -> Repo.get(Runtime, beta_runtime.id).status end) == "online"

    assert CommittedData.unboxed(fn ->
             Repo.all(
               from link in DaemonWorkspace,
                 where: link.daemon_id == ^daemon.id,
                 select: link.workspace_id
             )
           end) == [beta.id]
  end

  test "demotion preserves service configuration and registering again after promotion restores online state",
       %{
         acme_scope: owner_scope,
         daemon: daemon,
         epoch: epoch,
         acme: acme,
         acme_membership: membership,
         acme_runtime: runtime
       } do
    assert {:ok, _} =
             CommittedData.unboxed(fn ->
               Members.change_role(owner_scope, membership.id, :viewer)
             end)

    assert CommittedData.unboxed(fn -> Repo.get(Runtime, runtime.id).status end) == "offline"

    assert CommittedData.unboxed(fn ->
             Repo.exists?(
               from link in DaemonWorkspace,
                 where: link.daemon_id == ^daemon.id and link.workspace_id == ^acme.id
             )
           end)

    assert {:ok, remaining} =
             CommittedData.unboxed(fn -> Daemons.register(daemon.id, epoch, report()) end)

    refute Enum.any?(remaining, &(&1.workspace_id == acme.id))

    assert {:ok, _} =
             CommittedData.unboxed(fn ->
               Members.change_role(owner_scope, membership.id, :member)
             end)

    assert {:ok, registered} =
             CommittedData.unboxed(fn -> Daemons.register(daemon.id, epoch, report()) end)

    assert Enum.any?(registered, &(&1.workspace_id == acme.id))
    assert CommittedData.unboxed(fn -> Repo.get(Runtime, runtime.id).status end) == "online"
  end

  defp report do
    %HelmsmanProtocol.Report.Join{
      protocol: HelmsmanProtocol.version(),
      machine: %HelmsmanProtocol.Machine{os: "linux", arch: "x86_64", daemon_version: "0.9.0"},
      clis: [
        %HelmsmanProtocol.CLI{
          provider: :claude,
          version: "3.2.1",
          models: [],
          efforts: [],
          available: true
        }
      ],
      max_concurrency: 4,
      active_runs: []
    }
  end
end
