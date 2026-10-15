defmodule Helmsman.LocalRepositories.WebRegistrationTest do
  # add-local-repo-web-registration 3.3: who may ask a daemon to list,
  # register or remove local repositories, and what a request writes (D8).
  # The concurrent cases are in `WebRegistrationLockTest` below.
  use Helmsman.DataCase, async: true

  import Helmsman.AccountsFixtures
  import Helmsman.AgentsFixtures
  import Helmsman.LocalRepositoriesFixtures
  import Helmsman.WorkspacesFixtures

  alias Helmsman.Actors.Actor
  alias Helmsman.Daemons
  alias Helmsman.Daemons.Daemon
  alias Helmsman.Events
  alias Helmsman.LocalRepositories.{Change, WebRegistration}
  alias HelmsmanProtocol.{Push, Report}

  @v HelmsmanProtocol.repo_registration_version()

  setup do
    owner = user_fixture()
    alice = user_fixture()
    carol = user_fixture()
    acme = workspace_fixture(owner, %{name: "Acme"})
    beta = workspace_fixture(owner, %{name: "Beta"})
    member_fixture(acme, alice, :member)
    member_fixture(beta, alice, :member)
    member_fixture(acme, carol, :admin)

    daemon = eligible_daemon(alice, [acme.id, beta.id], %{name: "alice-mbp"})

    %{
      owner: owner,
      alice: alice,
      carol: carol,
      acme: acme,
      beta: beta,
      daemon: daemon,
      scope: workspace_scope_fixture(alice, acme),
      carol_scope: workspace_scope_fixture(carol, acme)
    }
  end

  defp eligible_daemon(user, workspace_ids, attrs \\ %{}) do
    {daemon, _token} =
      daemon_fixture(
        user,
        Map.merge(
          %{workspace_ids: workspace_ids, protocol_version: @v, repo_registration: true},
          attrs
        )
      )

    daemon
  end

  defp set_daemon(daemon, changes),
    do: Daemon |> Repo.get!(daemon.id) |> Ecto.Changeset.change(changes) |> Repo.update!()

  defp attrs(ctx, extra \\ %{}),
    do:
      Map.merge(
        %{"root" => "~/code", "path" => "app", "name" => "app", "workspace_ids" => [ctx.acme.id]},
        extra
      )

  defp changes, do: Repo.all(from(c in Change, order_by: c.id))

  defp listen(daemon), do: :ok = Events.subscribe(Events.topic(:daemon, daemon.id))

  defp offline_seen, do: DateTime.add(Daemons.now(), -(Daemons.online_threshold_seconds() + 5))

  describe "machines/1" do
    test "lists the requester's daemons serving the workspace, with their eligibility", ctx do
      other =
        eligible_daemon(ctx.alice, [ctx.acme.id], %{name: "old-mac", protocol_version: @v - 1})

      _beta_only = eligible_daemon(ctx.alice, [ctx.beta.id], %{name: "beta-only"})
      revoked = eligible_daemon(ctx.alice, [ctx.acme.id], %{name: "gone"})
      set_daemon(revoked, revoked_at: Daemons.now())
      _carols = eligible_daemon(ctx.carol, [ctx.acme.id], %{name: "carol-pc"})

      assert {:ok, [mbp, old]} = WebRegistration.machines(ctx.scope)
      assert %{daemon_id: id, name: "old-mac", eligibility: :daemon_outdated} = old
      assert id == other.id

      assert %{name: "alice-mbp", eligibility: :ok, workspaces: workspaces} = mbp
      assert mbp.daemon_id == ctx.daemon.id

      assert workspaces == [
               %{id: ctx.acme.id, slug: ctx.acme.slug, name: "Acme"},
               %{id: ctx.beta.id, slug: ctx.beta.slug, name: "Beta"}
             ]
    end

    test "shares only with workspaces where the requester is a member or above", ctx do
      Repo.update_all(
        from(m in Helmsman.Workspaces.Membership,
          where: m.user_id == ^ctx.alice.id and m.workspace_id == ^ctx.beta.id
        ),
        set: [role: :viewer]
      )

      assert {:ok, [%{workspaces: [%{id: id}]}]} = WebRegistration.machines(ctx.scope)
      assert id == ctx.acme.id
    end

    test "each eligibility reason", ctx do
      set_daemon(ctx.daemon, repo_registration: false)
      assert {:ok, [%{eligibility: :registration_disabled}]} = WebRegistration.machines(ctx.scope)

      set_daemon(ctx.daemon, repo_registration: true, last_seen_at: offline_seen())
      assert {:ok, [%{eligibility: :daemon_offline}]} = WebRegistration.machines(ctx.scope)

      set_daemon(ctx.daemon, protocol_version: nil)
      assert {:ok, [%{eligibility: :daemon_outdated}]} = WebRegistration.machines(ctx.scope)
    end

    test "a viewer or a token is forbidden", ctx do
      {_viewer, viewer_scope} = viewer(ctx.acme)
      assert {:error, :forbidden} = WebRegistration.machines(viewer_scope)
      assert {:error, :forbidden} = WebRegistration.machines(%{ctx.scope | via: :api})
    end
  end

  defp viewer(workspace) do
    user = user_fixture()
    member_fixture(workspace, user, :viewer)
    {user, workspace_scope_fixture(user, workspace)}
  end

  # Every entry point with the same daemon / repository.
  defp each_request(ctx, scope) do
    repo =
      Repo.get_by(Helmsman.LocalRepositories.LocalRepository,
        workspace_id: ctx.acme.id,
        daemon_id: ctx.daemon.id,
        name: "app"
      ) || local_repository_fixture(ctx.acme, ctx.daemon)

    [
      browse: WebRegistration.browse(scope, ctx.daemon.id),
      register: WebRegistration.register(scope, ctx.daemon.id, attrs(ctx)),
      remove: WebRegistration.remove(scope, repo.id)
    ]
  end

  describe "eligibility" do
    test "the owner's request reaches the daemon (scenario: owner registers)", ctx do
      listen(ctx.daemon)
      assert {:ok, request_id} = WebRegistration.browse(ctx.scope, ctx.daemon.id)
      assert request_id =~ ~r/^[A-Za-z0-9_-]{22}$/
      assert_receive {:local_repo_request, %Push.RepoBrowse{request_id: ^request_id}}
    end

    test "a workspace admin cannot act on another user's machine", ctx do
      listen(ctx.daemon)

      for {action, result} <- each_request(ctx, ctx.carol_scope) do
        assert {action, {:error, :not_found}} == {action, result}
      end

      refute_receive {:local_repo_request, _}
      assert changes() == []
    end

    test "REST, MCP, runs and agents are forbidden", ctx do
      agent = %Actor{kind: :agent, workspace_id: ctx.acme.id}

      for scope <- [
            %{ctx.scope | via: :api},
            %{ctx.scope | via: :mcp},
            %{ctx.scope | via: :run},
            %{ctx.scope | actor: agent}
          ],
          {action, result} <- each_request(ctx, scope) do
        assert {action, {:error, :forbidden}} == {action, result}
      end

      assert changes() == []
    end

    test "a viewer is forbidden, even on their own machine", ctx do
      {viewer, scope} = viewer(ctx.acme)
      daemon = eligible_daemon(viewer, [ctx.acme.id])
      assert {:error, :forbidden} = WebRegistration.browse(scope, daemon.id)

      assert {:error, :forbidden} =
               WebRegistration.register(scope, daemon.id, attrs(ctx))
    end

    test "a revoked machine, or one not serving the workspace, is not found", ctx do
      beta_only = eligible_daemon(ctx.alice, [ctx.beta.id])
      assert {:error, :not_found} = WebRegistration.browse(ctx.scope, beta_only.id)

      set_daemon(ctx.daemon, revoked_at: Daemons.now())

      for {action, result} <- each_request(ctx, ctx.scope) do
        assert {action, {:error, :not_found}} == {action, result}
      end

      assert {:error, :not_found} = WebRegistration.browse(ctx.scope, -1)
      assert {:error, :not_found} = WebRegistration.browse(ctx.scope, "1")
    end

    test "the first failed reason is returned, in order", ctx do
      {_viewer, viewer_scope} = viewer(ctx.acme)
      carols = eligible_daemon(ctx.carol, [ctx.acme.id], %{protocol_version: @v - 1})

      # forbidden before not_found
      assert {:error, :forbidden} = WebRegistration.browse(viewer_scope, carols.id)
      # not_found before daemon_outdated
      assert {:error, :not_found} = WebRegistration.browse(ctx.scope, carols.id)

      set_daemon(ctx.daemon,
        protocol_version: @v - 1,
        repo_registration: false,
        last_seen_at: offline_seen()
      )

      assert {:error, :daemon_outdated} = WebRegistration.browse(ctx.scope, ctx.daemon.id)

      set_daemon(ctx.daemon, protocol_version: @v)
      assert {:error, :registration_disabled} = WebRegistration.browse(ctx.scope, ctx.daemon.id)

      set_daemon(ctx.daemon, repo_registration: true)

      for {action, result} <- each_request(ctx, ctx.scope) do
        assert {action, {:error, :daemon_offline}} == {action, result}
      end

      set_daemon(ctx.daemon, last_seen_at: nil)
      assert {:error, :daemon_offline} = WebRegistration.browse(ctx.scope, ctx.daemon.id)
    end

    test "an old daemon gets nothing (scenario)", ctx do
      listen(ctx.daemon)
      set_daemon(ctx.daemon, protocol_version: @v - 1)

      for {action, result} <- each_request(ctx, ctx.scope) do
        assert {action, {:error, :daemon_outdated}} == {action, result}
      end

      refute_receive {:local_repo_request, _}
    end

    test "a machine that does not allow web registration (scenario)", ctx do
      set_daemon(ctx.daemon, repo_registration: false)
      assert {:error, :registration_disabled} = WebRegistration.browse(ctx.scope, ctx.daemon.id)
    end
  end

  describe "browse/2" do
    test "writes nothing and delivers the result to the caller only", ctx do
      assert {:ok, request_id} = WebRegistration.browse(ctx.scope, ctx.daemon.id)
      assert changes() == []

      report = %Report.RepoBrowseResult{
        request_id: request_id,
        error: nil,
        message: nil,
        roots: ["~/code"],
        repositories: [%{root: "~/code", path: "app", name: "app", registered_as: nil}],
        truncated: false
      }

      assert :ok = WebRegistration.deliver(daemon_ctx(ctx.daemon), report)
      daemon_id = ctx.daemon.id

      assert_receive {:local_repo_result, ^request_id, ^daemon_id,
                      {:ok,
                       %{roots: ["~/code"], repositories: [%{path: "app"}], truncated: false}}}

      assert changes() == []

      WebRegistration.forget(request_id)
      assert :ok = WebRegistration.deliver(daemon_ctx(ctx.daemon), report)
      refute_receive {:local_repo_result, _, _, _}
    end

    test "a browse error reaches the caller as a code", ctx do
      assert {:ok, request_id} = WebRegistration.browse(ctx.scope, ctx.daemon.id)

      report = %Report.RepoBrowseResult{
        request_id: request_id,
        error: :disabled,
        message: "no allowed roots",
        roots: [],
        repositories: [],
        truncated: false
      }

      assert :ok = WebRegistration.deliver(daemon_ctx(ctx.daemon), report)
      assert_receive {:local_repo_result, ^request_id, _, {:error, :disabled, "no allowed roots"}}
    end
  end

  defp daemon_ctx(daemon) do
    daemon = Repo.get!(Daemon, daemon.id)

    %{
      daemon_id: daemon.id,
      user_id: daemon.user_id,
      auth_epoch: daemon.auth_epoch,
      protocol: daemon.protocol_version
    }
  end

  describe "register/3" do
    test "records a pending change and sends the request", ctx do
      listen(ctx.daemon)
      Events.subscribe(Events.topic(:workspace, ctx.acme.id))
      Events.subscribe(Events.topic(:workspace, ctx.beta.id))

      assert {:ok, request_id} =
               WebRegistration.register(
                 ctx.scope,
                 ctx.daemon.id,
                 attrs(ctx, %{
                   "path" => "group/app",
                   "workspace_ids" => [ctx.beta.id, ctx.acme.id]
                 })
               )

      beta_id = ctx.beta.id
      acme_id = ctx.acme.id

      assert_receive {:local_repo_request,
                      %Push.RepoRegister{
                        request_id: ^request_id,
                        root: "~/code",
                        path: "group/app",
                        name: "app",
                        workspaces: [^beta_id, ^acme_id]
                      }}

      assert_receive {:local_repository_changes_changed}
      assert_receive {:local_repository_changes_changed}
      refute_receive {:local_repository_changes_changed}, 20

      assert [change] = changes()

      assert %Change{
               action: "register",
               status: "pending",
               name: "app",
               root: "~/code",
               path: "group/app",
               workspace_ids: [^beta_id, ^acme_id],
               request_id: ^request_id,
               error: nil,
               completed_at: nil
             } = change

      assert change.user_id == ctx.alice.id
      assert change.workspace_id == ctx.acme.id
      assert change.daemon_id == ctx.daemon.id
    end

    test "invalid fields are a changeset; nothing is sent", ctx do
      listen(ctx.daemon)
      other = workspace_fixture(user_fixture())

      for {field, extra} <- [
            path: %{"path" => "../secret"},
            path: %{"path" => "/etc"},
            path: %{"path" => "app/./x"},
            path: %{"path" => "app//x"},
            path: %{"path" => "app/"},
            path: %{"path" => "a\nb"},
            path: %{"path" => Enum.map_join(1..17, "/", fn _ -> "a" end)},
            root: %{"root" => ""},
            root: %{"root" => "~/co\0de"},
            root: %{"root" => String.duplicate("r", 1025)},
            name: %{"name" => "App"},
            name: %{"name" => "-app"},
            name: %{"name" => nil},
            workspace_ids: %{"workspace_ids" => []},
            workspace_ids: %{"workspace_ids" => [ctx.acme.id, ctx.acme.id]},
            # Scenario: a workspace the daemon does not serve.
            workspace_ids: %{"workspace_ids" => [ctx.acme.id, other.id]},
            workspace_ids: %{"workspace_ids" => ["x"]}
          ] do
        assert {:error, %Ecto.Changeset{} = changeset} =
                 WebRegistration.register(ctx.scope, ctx.daemon.id, attrs(ctx, extra))

        assert Keyword.has_key?(changeset.errors, field), "#{inspect(extra)}"
      end

      refute_receive {:local_repo_request, _}
      assert changes() == []
    end

    test "valid edge formats are accepted", ctx do
      for {extra, n} <- Enum.with_index([%{"path" => "."}, %{"path" => "group/lib"}]) do
        Repo.delete_all(Change)

        assert {:ok, _} =
                 WebRegistration.register(
                   ctx.scope,
                   ctx.daemon.id,
                   attrs(ctx, Map.put(extra, "name", "app#{n}"))
                 )
      end
    end

    test "a pending request within 30 seconds makes the next one busy", ctx do
      listen(ctx.daemon)
      assert {:ok, _} = WebRegistration.register(ctx.scope, ctx.daemon.id, attrs(ctx))
      assert_receive {:local_repo_request, _}

      assert {:error, :busy} =
               WebRegistration.register(ctx.scope, ctx.daemon.id, attrs(ctx, %{"name" => "lib"}))

      repo = local_repository_fixture(ctx.acme, ctx.daemon, %{name: "old"})
      assert {:error, :busy} = WebRegistration.remove(ctx.scope, repo.id)
      refute_receive {:local_repo_request, _}

      Repo.update_all(Change, set: [inserted_at: DateTime.add(DateTime.utc_now(), -31)])

      assert {:ok, _} =
               WebRegistration.register(ctx.scope, ctx.daemon.id, attrs(ctx, %{"name" => "lib"}))

      assert_receive {:local_repo_request, %Push.RepoRegister{name: "lib"}}
    end

    test "a completed request does not make the next one busy", ctx do
      assert {:ok, _} = WebRegistration.register(ctx.scope, ctx.daemon.id, attrs(ctx))
      Repo.update_all(Change, set: [status: "succeeded", completed_at: DateTime.utc_now()])
      assert {:ok, _} = WebRegistration.register(ctx.scope, ctx.daemon.id, attrs(ctx))
    end

    test "the caller is subscribed before the request goes out", ctx do
      daemon_id = ctx.daemon.id
      fake_channel(daemon_id)

      assert {:ok, request_id} = WebRegistration.register(ctx.scope, daemon_id, attrs(ctx))
      assert_receive {:local_repo_result, ^request_id, ^daemon_id, {:ok, :echo}}

      assert {:ok, request_id} = WebRegistration.browse(ctx.scope, daemon_id)
      assert_receive {:local_repo_result, ^request_id, ^daemon_id, {:ok, :echo}}
    end
  end

  # Subscribed to the daemon topic, it answers every request at once.
  defp fake_channel(daemon_id) do
    test = self()

    pid =
      spawn_link(fn ->
        :ok = Events.subscribe(Events.topic(:daemon, daemon_id))
        send(test, :fake_channel_ready)
        echo(daemon_id)
      end)

    assert_receive :fake_channel_ready
    pid
  end

  defp echo(daemon_id) do
    receive do
      {:local_repo_request, push} ->
        Events.broadcast(
          WebRegistration.topic(push.request_id),
          {:local_repo_result, push.request_id, daemon_id, {:ok, :echo}}
        )

        echo(daemon_id)
    end
  end

  describe "remove/2" do
    test "sends the removal and records every workspace the entry is in", ctx do
      listen(ctx.daemon)
      gamma = workspace_fixture(ctx.owner)
      delta = workspace_fixture(ctx.owner)
      repo = local_repository_fixture(ctx.acme, ctx.daemon)
      local_repository_fixture(ctx.beta, ctx.daemon)
      local_repository_fixture(gamma, ctx.daemon)
      local_repository_fixture(delta, ctx.daemon, %{removed_at: Daemons.now()})
      local_repository_fixture(ctx.beta, ctx.daemon, %{name: "lib"})

      assert {:ok, request_id} = WebRegistration.remove(ctx.scope, repo.id)
      assert_receive {:local_repo_request, %Push.RepoRemove{request_id: ^request_id, name: "app"}}

      assert [%Change{action: "remove", name: "app", root: nil, path: nil} = change] = changes()
      assert change.workspace_ids == Enum.sort([ctx.acme.id, ctx.beta.id, gamma.id])
      assert change.workspace_id == ctx.acme.id
    end

    test "remove_workspaces/2 lists what the removal records, for the owner only", ctx do
      gamma = workspace_fixture(ctx.owner, %{name: "Gamma"})
      repo = local_repository_fixture(ctx.acme, ctx.daemon)
      local_repository_fixture(ctx.beta, ctx.daemon)
      local_repository_fixture(gamma, ctx.daemon, %{removed_at: Daemons.now()})
      local_repository_fixture(gamma, ctx.daemon, %{name: "lib"})

      assert {:ok, workspaces} = WebRegistration.remove_workspaces(ctx.scope, repo.id)

      assert workspaces == [
               %{id: ctx.acme.id, slug: ctx.acme.slug, name: "Acme"},
               %{id: ctx.beta.id, slug: ctx.beta.slug, name: "Beta"}
             ]

      assert {:ok, _} = WebRegistration.remove(ctx.scope, repo.id)
      assert [%Change{workspace_ids: ids}] = changes()
      assert ids == Enum.map(workspaces, & &1.id)

      # Whatever the daemon's state; only its owner, in the row's workspace.
      set_daemon(ctx.daemon, repo_registration: false, last_seen_at: nil)
      assert {:ok, [_, _]} = WebRegistration.remove_workspaces(ctx.scope, repo.id)
      assert {:error, :not_found} = WebRegistration.remove_workspaces(ctx.carol_scope, repo.id)

      assert {:error, :not_found} =
               WebRegistration.remove_workspaces(
                 workspace_scope_fixture(ctx.alice, ctx.beta),
                 repo.id
               )

      assert {:error, :forbidden} =
               WebRegistration.remove_workspaces(%{ctx.scope | via: :api}, repo.id)

      set_daemon(ctx.daemon, revoked_at: Daemons.now())
      assert {:error, :not_found} = WebRegistration.remove_workspaces(ctx.scope, repo.id)
      assert {:error, :not_found} = WebRegistration.remove_workspaces(ctx.scope, -1)
    end

    test "only a current row of the workspace", ctx do
      beta_row = local_repository_fixture(ctx.beta, ctx.daemon)
      removed = local_repository_fixture(ctx.acme, ctx.daemon, %{removed_at: Daemons.now()})
      carols = eligible_daemon(ctx.carol, [ctx.acme.id])
      carol_row = local_repository_fixture(ctx.acme, carols)

      assert {:error, :not_found} = WebRegistration.remove(ctx.scope, beta_row.id)
      assert {:error, :not_found} = WebRegistration.remove(ctx.scope, removed.id)
      assert {:error, :not_found} = WebRegistration.remove(ctx.scope, carol_row.id)
      assert {:error, :not_found} = WebRegistration.remove(ctx.scope, -1)
      assert {:error, :not_found} = WebRegistration.remove(ctx.scope, "x")
      assert changes() == []
    end

    test "a row no longer configured on the machine is not sent", ctx do
      listen(ctx.daemon)

      repo =
        local_repository_fixture(ctx.acme, ctx.daemon, %{
          status: "unavailable",
          unavailable_reason: "not configured on the machine"
        })

      assert {:error, :not_configured} = WebRegistration.remove(ctx.scope, repo.id)
      refute_receive {:local_repo_request, _}
      assert changes() == []
    end
  end
end

defmodule Helmsman.LocalRepositories.WebRegistrationLockTest do
  # add-local-repo-web-registration 3.3 (review 1 P2-1, P2-3): concurrent
  # requests on connections of their own, paused at the
  # `Helmsman.Daemons.Locking` hooks.
  use ExUnit.Case, async: false

  import Ecto.Query
  import Helmsman.AccountsFixtures
  import Helmsman.AgentsFixtures
  import Helmsman.WorkspacesFixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias Helmsman.{CommittedData, Daemons, Events, LockHarness, Repo}
  alias Helmsman.LocalRepositories.{Change, WebRegistration}
  alias Helmsman.Workspaces.Membership

  @v HelmsmanProtocol.repo_registration_version()

  setup do
    :ok = Sandbox.mode(Repo, :auto)
    on_exit(fn -> Sandbox.mode(Repo, :manual) end)

    tag = System.unique_integer([:positive])

    data =
      CommittedData.unboxed(fn ->
        owner = user_fixture(%{email: "lrweb-owner-#{tag}@test.invalid"})
        alice = user_fixture(%{email: "lrweb-alice-#{tag}@test.invalid"})
        acme = workspace_fixture(owner, %{name: "Acme #{tag}"})
        beta = workspace_fixture(owner, %{name: "Beta #{tag}"})
        member_fixture(acme, alice, :member)
        member_fixture(beta, alice, :member)

        {daemon, _token} =
          daemon_fixture(alice, %{
            workspace_ids: [acme.id, beta.id],
            protocol_version: @v,
            repo_registration: true
          })

        %{
          owner: owner,
          alice: alice,
          acme: acme,
          beta: beta,
          daemon: daemon,
          scope: workspace_scope_fixture(alice, acme),
          owner_beta: workspace_scope_fixture(owner, beta)
        }
      end)

    on_exit(fn ->
      CommittedData.delete_user_data!([data.owner.id, data.alice.id], [data.acme.id, data.beta.id])
    end)

    data
  end

  defp attrs(name, ids),
    do: %{root: "~/code", path: name, name: name, workspace_ids: ids}

  defp register(ctx, name, ids \\ nil),
    do: fn ->
      WebRegistration.register(ctx.scope, ctx.daemon.id, attrs(name, ids || [ctx.acme.id]))
    end

  defp changes(daemon),
    do:
      CommittedData.unboxed(fn ->
        Repo.all(from(c in Change, where: c.daemon_id == ^daemon.id))
      end)

  test "two concurrent registrations: at most one is recorded and sent", ctx do
    :ok = Events.subscribe(Events.topic(:daemon, ctx.daemon.id))

    {first, second} =
      LockHarness.interleave(register(ctx, "app"), :daemon_locked, register(ctx, "lib"))

    assert {:ok, _} = first
    assert {:error, :busy} = second
    assert [%Change{name: "app"}] = changes(ctx.daemon)
    assert_receive {:local_repo_request, %{name: "app"}}
    refute_receive {:local_repo_request, _}, 100
  end

  test "a registration and a removal are serialized too", ctx do
    repo =
      CommittedData.unboxed(fn ->
        Helmsman.LocalRepositoriesFixtures.local_repository_fixture(ctx.acme, ctx.daemon, %{
          name: "old"
        })
      end)

    remove = fn -> WebRegistration.remove(ctx.scope, repo.id) end
    {first, second} = LockHarness.interleave(remove, :daemon_locked, register(ctx, "lib"))

    assert {:ok, _} = first
    assert {:error, :busy} = second
    assert [%Change{action: "remove"}] = changes(ctx.daemon)
  end

  test "the 30 seconds count from after the lock is taken", ctx do
    CommittedData.unboxed(fn ->
      Repo.insert!(%Change{
        daemon_id: ctx.daemon.id,
        user_id: ctx.alice.id,
        workspace_id: ctx.acme.id,
        action: "remove",
        name: "old",
        request_id: "pending-request-#{System.unique_integer([:positive])}xxxxxx",
        inserted_at: DateTime.add(DateTime.utc_now(), -29)
      })
    end)

    side = LockHarness.start(register(ctx, "app"), pause: :daemon_locked)
    LockHarness.await_paused(side)
    Process.sleep(2_100)
    LockHarness.continue(side)

    assert {:ok, _} = LockHarness.result(side)
    assert length(changes(ctx.daemon)) == 2
  end

  describe "the chosen workspaces are checked again under the lock" do
    setup ctx do
      :ok = Events.subscribe(Events.topic(:daemon, ctx.daemon.id))
      :ok
    end

    defp after_pre_read(ctx, change) do
      side =
        LockHarness.start(register(ctx, "app", [ctx.acme.id, ctx.beta.id]),
          pause: :daemon_pre_read
        )

      LockHarness.await_paused(side)
      CommittedData.unboxed(change)
      LockHarness.continue(side)
      beta_id = ctx.beta.id
      assert {:error, {:invalid_workspaces, [^beta_id]}} = LockHarness.result(side)
      assert changes(ctx.daemon) == []
      refute_receive {:local_repo_request, _}, 100
    end

    defp beta_membership(ctx),
      do:
        from(m in Membership,
          where: m.user_id == ^ctx.alice.id and m.workspace_id == ^ctx.beta.id
        )

    test "the requester became a viewer of beta", ctx do
      after_pre_read(ctx, fn -> Repo.update_all(beta_membership(ctx), set: [role: :viewer]) end)
    end

    test "the requester left beta", ctx do
      after_pre_read(ctx, fn -> Repo.delete_all(beta_membership(ctx)) end)
    end

    test "the daemon no longer serves beta", ctx do
      scope = ctx.scope

      after_pre_read(ctx, fn ->
        {:ok, _} = Daemons.set_workspaces(scope, ctx.daemon.id, [ctx.acme.id])
      end)
    end
  end
end

defmodule Helmsman.LocalRepositories.WebRegistrationLogTest do
  # add-local-repo-web-registration 3.3: what the server logs (D8). The
  # log level is global, hence not async.
  use Helmsman.DataCase, async: false

  import ExUnit.CaptureLog
  import Helmsman.AccountsFixtures
  import Helmsman.AgentsFixtures
  import Helmsman.WorkspacesFixtures

  alias Helmsman.LocalRepositories.WebRegistration
  alias HelmsmanProtocol.Report

  setup do
    alice = user_fixture()
    acme = workspace_fixture(alice)

    {daemon, _token} =
      daemon_fixture(alice, %{
        workspace_ids: [acme.id],
        protocol_version: HelmsmanProtocol.repo_registration_version(),
        repo_registration: true
      })

    scope = workspace_scope_fixture(alice, acme)
    level = Logger.level()
    Logger.configure(level: :debug)
    on_exit(fn -> Logger.configure(level: level) end)

    %{
      daemon: daemon,
      daemon_ctx: %{daemon_id: daemon.id, user_id: alice.id, auth_epoch: daemon.auth_epoch},
      scope: scope,
      acme: acme
    }
  end

  defp attrs(ctx, extra),
    do:
      Map.merge(
        %{"root" => "~/code", "path" => "app", "name" => "app", "workspace_ids" => [ctx.acme.id]},
        extra
      )

  test "logs carry the request ID, never the root or path", ctx do
    log =
      capture_log([level: :debug], fn ->
        {:ok, id} =
          WebRegistration.register(
            ctx.scope,
            ctx.daemon.id,
            attrs(ctx, %{"root" => "/srv/secret-root", "path" => "hidden/where"})
          )

        {:ok, browse_id} = WebRegistration.browse(ctx.scope, ctx.daemon.id)

        WebRegistration.deliver(ctx.daemon_ctx, %Report.RepoBrowseResult{
          request_id: browse_id,
          error: nil,
          message: nil,
          roots: ["/srv/secret-root"],
          repositories: [
            %{root: "/srv/secret-root", path: "hidden/where", name: "x", registered_as: nil}
          ],
          truncated: false
        })

        WebRegistration.deliver(ctx.daemon_ctx, %Report.RepoChangeResult{
          request_id: id,
          action: :register,
          name: "app",
          error: :outside_root,
          message: "outside the root"
        })

        send(self(), {:ids, id, browse_id})
      end)

    assert_received {:ids, id, browse_id}
    assert log =~ id
    assert log =~ browse_id
    refute log =~ "secret-root"
    refute log =~ "hidden"
  end
end
