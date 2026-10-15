defmodule Helmsman.LocalRepositories.WebRegistrationChangesTest do
  # add-local-repo-web-registration 3.5: the record of web registrations
  # and removals (D10) and how results are written to it (D8 `deliver/2`,
  # `undeliverable/2`).
  use Helmsman.DataCase, async: true

  import Helmsman.AccountsFixtures
  import Helmsman.AgentsFixtures
  import Helmsman.LocalRepositoriesFixtures
  import Helmsman.WorkspacesFixtures

  alias Helmsman.Daemons.Daemon
  alias Helmsman.Events
  alias Helmsman.LocalRepositories.{Change, WebRegistration}
  alias HelmsmanProtocol.Report

  @v HelmsmanProtocol.repo_registration_version()

  setup do
    owner = user_fixture()
    alice = user_fixture()
    bob = user_fixture()
    carol = user_fixture()
    acme = workspace_fixture(owner, %{name: "Acme"})
    beta = workspace_fixture(owner, %{name: "Beta"})
    member_fixture(acme, alice, :member)
    member_fixture(beta, alice, :member)
    member_fixture(acme, bob, :member)
    member_fixture(acme, carol, :admin)

    {daemon, _token} =
      daemon_fixture(alice, %{
        name: "alice-mbp",
        workspace_ids: [acme.id, beta.id],
        protocol_version: @v,
        repo_registration: true
      })

    %{
      alice: alice,
      acme: acme,
      beta: beta,
      daemon: daemon,
      scope: workspace_scope_fixture(alice, acme),
      bob_scope: workspace_scope_fixture(bob, acme),
      carol_scope: workspace_scope_fixture(carol, acme),
      beta_owner_scope: workspace_scope_fixture(owner, beta)
    }
  end

  defp register(ctx, extra \\ %{}) do
    attrs =
      Map.merge(
        %{
          root: "~/code",
          path: "app",
          name: "app",
          workspace_ids: [ctx.acme.id, ctx.beta.id]
        },
        extra
      )

    {:ok, request_id} = WebRegistration.register(ctx.scope, ctx.daemon.id, attrs)
    request_id
  end

  defp ctx_of(daemon) do
    daemon = Repo.get!(Daemon, daemon.id)
    %{daemon_id: daemon.id, user_id: daemon.user_id, auth_epoch: daemon.auth_epoch}
  end

  defp result(request_id, attrs \\ %{}),
    do:
      struct!(
        Report.RepoChangeResult,
        Map.merge(
          %{request_id: request_id, action: :register, name: "app", error: nil, message: nil},
          attrs
        )
      )

  defp record(request_id), do: Repo.get_by!(Change, request_id: request_id)

  defp age(request_id, seconds),
    do:
      Repo.update_all(from(c in Change, where: c.request_id == ^request_id),
        set: [inserted_at: DateTime.add(DateTime.utc_now(), -seconds)]
      )

  describe "results" do
    test "a successful registration is recorded (scenario)", ctx do
      request_id = register(ctx)
      daemon_id = ctx.daemon.id
      assert :ok = WebRegistration.deliver(ctx_of(ctx.daemon), result(request_id))

      assert_receive {:local_repo_result, ^request_id, ^daemon_id,
                      {:ok, %{action: :register, name: "app"}}}

      record = record(request_id)
      assert record.status == "succeeded"
      assert record.workspace_ids == [ctx.acme.id, ctx.beta.id]
      assert record.completed_at

      assert {:ok, [view]} = WebRegistration.list_changes(ctx.scope, :mine)

      assert %{
               action: :register,
               name: "app",
               daemon_name: "alice-mbp",
               root: "~/code",
               path: "app",
               state: :succeeded,
               error: nil,
               message: nil
             } = view

      assert view.operator.user_id == ctx.alice.id
      assert view.operator.name
      assert view.inserted_at
      assert view.completed_at
    end

    test "a failure is recorded with its code (scenario)", ctx do
      request_id = register(ctx)

      assert :ok =
               WebRegistration.deliver(
                 ctx_of(ctx.daemon),
                 result(request_id, %{error: :outside_root, message: "outside the root"})
               )

      assert_receive {:local_repo_result, ^request_id, _,
                      {:error, :outside_root, "outside the root"}}

      assert %Change{status: "failed", error: "outside_root", message: "outside the root"} =
               record(request_id)

      assert {:ok, [%{state: :failed, error: :outside_root}]} =
               WebRegistration.list_changes(ctx.scope, :mine)
    end

    test "a result from another daemon, or for another action or name, is ignored", ctx do
      request_id = register(ctx)
      {other, _token} = daemon_fixture(user_fixture(), %{protocol_version: @v})

      assert :ok = WebRegistration.deliver(ctx_of(other), result(request_id))

      assert :ok =
               WebRegistration.deliver(ctx_of(ctx.daemon), result(request_id, %{action: :remove}))

      assert :ok = WebRegistration.deliver(ctx_of(ctx.daemon), result(request_id, %{name: "lib"}))
      assert :ok = WebRegistration.deliver(ctx_of(ctx.daemon), result("unknown-request-0000000"))

      refute_receive {:local_repo_result, _, _, _}
      assert %Change{status: "pending", completed_at: nil} = record(request_id)

      # The daemon's own result still counts afterwards.
      assert :ok = WebRegistration.deliver(ctx_of(ctx.daemon), result(request_id))
      assert_receive {:local_repo_result, ^request_id, _, {:ok, _}}
      assert record(request_id).status == "succeeded"
    end

    test "a result is written once", ctx do
      request_id = register(ctx)
      assert :ok = WebRegistration.deliver(ctx_of(ctx.daemon), result(request_id))
      assert_receive {:local_repo_result, ^request_id, _, {:ok, _}}
      completed = record(request_id).completed_at

      assert :ok =
               WebRegistration.deliver(
                 ctx_of(ctx.daemon),
                 result(request_id, %{error: :busy})
               )

      refute_receive {:local_repo_result, _, _, _}

      assert %Change{status: "succeeded", error: nil, completed_at: ^completed} =
               record(request_id)
    end

    test "a stale authorization is not found and writes nothing", ctx do
      request_id = register(ctx)
      stale = ctx_of(ctx.daemon)

      Repo.update_all(from(d in Daemon, where: d.id == ^ctx.daemon.id),
        inc: [auth_epoch: 1]
      )

      assert {:error, :not_found} = WebRegistration.deliver(stale, result(request_id))
      assert record(request_id).status == "pending"

      Repo.update_all(from(d in Daemon, where: d.id == ^ctx.daemon.id),
        set: [revoked_at: DateTime.utc_now(:second)]
      )

      assert {:error, :not_found} =
               WebRegistration.deliver(ctx_of(ctx.daemon), result(request_id))

      refute_receive {:local_repo_result, _, _, _}
    end

    test "a removal result", ctx do
      repo = local_repository_fixture(ctx.acme, ctx.daemon)
      {:ok, request_id} = WebRegistration.remove(ctx.scope, repo.id)

      assert :ok =
               WebRegistration.deliver(ctx_of(ctx.daemon), result(request_id, %{action: :remove}))

      assert_receive {:local_repo_result, ^request_id, _, {:ok, %{action: :remove, name: "app"}}}

      assert {:ok, [%{action: :remove, root: nil, path: nil, state: :succeeded}]} =
               WebRegistration.list_changes(ctx.scope, :mine)
    end

    test "an undeliverable request fails as daemon_outdated", ctx do
      request_id = register(ctx)
      daemon_id = ctx.daemon.id
      assert :ok = WebRegistration.undeliverable(request_id, daemon_id)

      assert_receive {:local_repo_result, ^request_id, ^daemon_id,
                      {:error, :daemon_outdated, nil}}

      assert %Change{status: "failed", error: "daemon_outdated"} = record(request_id)

      # Already answered: nothing more.
      assert :ok = WebRegistration.undeliverable(request_id, daemon_id)
      refute_receive {:local_repo_result, _, _, _}

      {:ok, browse_id} = WebRegistration.browse(ctx.scope, daemon_id)
      assert :ok = WebRegistration.undeliverable(browse_id, daemon_id)
      assert_receive {:local_repo_result, ^browse_id, ^daemon_id, {:error, :daemon_outdated, nil}}
    end
  end

  describe "list_changes/2" do
    test "no reply after 60 seconds; a late result is still written (scenario)", ctx do
      request_id = register(ctx)
      age(request_id, 59)
      assert {:ok, [%{state: :pending}]} = WebRegistration.list_changes(ctx.scope, :mine)

      age(request_id, 61)

      assert {:ok, [%{state: :no_reply, completed_at: nil}]} =
               WebRegistration.list_changes(ctx.scope, :mine)

      age(request_id, 600)
      assert :ok = WebRegistration.deliver(ctx_of(ctx.daemon), result(request_id))
      assert {:ok, [%{state: :succeeded}]} = WebRegistration.list_changes(ctx.scope, :mine)
    end

    test "who sees which records (scenario)", ctx do
      request_id = register(ctx)

      # bob (member) sees only his own; he may not ask for everyone's.
      assert {:ok, []} = WebRegistration.list_changes(ctx.bob_scope, :mine)
      assert {:error, :forbidden} = WebRegistration.list_changes(ctx.bob_scope, :all)

      # carol (admin of acme) sees it with its location.
      assert {:ok, []} = WebRegistration.list_changes(ctx.carol_scope, :mine)

      assert {:ok, [%{root: "~/code", path: "app", operator: %{user_id: alice_id}}]} =
               WebRegistration.list_changes(ctx.carol_scope, :all)

      assert alice_id == ctx.alice.id

      # beta's owner sees it in beta, where it was shared.
      assert {:ok, [%{root: "~/code"}]} = WebRegistration.list_changes(ctx.beta_owner_scope, :all)

      # A workspace it does not involve shows nothing.
      gamma = workspace_fixture(ctx.alice)
      gamma_scope = workspace_scope_fixture(ctx.alice, gamma)
      assert {:ok, []} = WebRegistration.list_changes(gamma_scope, :all)

      assert record(request_id)
    end

    test "a viewer is forbidden", ctx do
      viewer = user_fixture()
      member_fixture(ctx.acme, viewer, :viewer)
      scope = workspace_scope_fixture(viewer, ctx.acme)
      assert {:error, :forbidden} = WebRegistration.list_changes(scope, :mine)
      assert {:error, :forbidden} = WebRegistration.list_changes(scope, :all)
    end

    test "at most 20, newest first", ctx do
      now = DateTime.utc_now()

      for n <- 1..22 do
        Repo.insert!(%Change{
          daemon_id: ctx.daemon.id,
          user_id: ctx.alice.id,
          workspace_id: ctx.acme.id,
          action: "remove",
          name: "repo#{n}",
          request_id: "request-#{n}-#{System.unique_integer([:positive])}-xxxxxxxxxx",
          status: "succeeded",
          inserted_at: DateTime.add(now, n - 100),
          completed_at: now
        })
      end

      assert {:ok, views} = WebRegistration.list_changes(ctx.scope, :mine)
      assert length(views) == 20
      assert hd(views).name == "repo22"
      assert List.last(views).name == "repo3"
    end

    test "each involved workspace hears of a new record and of its result", ctx do
      Events.subscribe(Events.topic(:workspace, ctx.acme.id))
      Events.subscribe(Events.topic(:workspace, ctx.beta.id))

      request_id = register(ctx)
      assert_receive {:local_repository_changes_changed}
      assert_receive {:local_repository_changes_changed}
      refute_receive {:local_repository_changes_changed}, 20

      assert :ok = WebRegistration.deliver(ctx_of(ctx.daemon), result(request_id))
      assert_receive {:local_repository_changes_changed}
      assert_receive {:local_repository_changes_changed}
      refute_receive {:local_repository_changes_changed}, 20
    end
  end
end
