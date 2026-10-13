defmodule Helmsman.Daemons.RegisterLocalReposTest do
  # add-local-repositories 2.2: local repositories registered from join /
  # sync (decision 4) and who sees their paths.
  use Helmsman.DataCase, async: true

  import Helmsman.AccountsFixtures
  import Helmsman.AgentsFixtures
  import Helmsman.LocalRepositoriesFixtures
  import Helmsman.ProjectsFixtures
  import Helmsman.RunsFixtures
  import Helmsman.WorkspacesFixtures

  alias Helmsman.{Daemons, Events, LocalRepositories, Projects}
  alias Helmsman.Daemons.Daemon
  alias Helmsman.Daemons.Workers.MarkOffline
  alias Helmsman.LocalRepositories.LocalRepository

  setup do
    alice = user_fixture()
    ws7 = workspace_fixture(alice)
    ws9 = workspace_fixture(alice)
    scope7 = workspace_scope_fixture(alice, ws7)
    scope9 = workspace_scope_fixture(alice, ws9)

    {daemon, _token} =
      daemon_fixture(alice, %{workspace_ids: [ws7.id, ws9.id], name: "alice-mbp"})

    %{alice: alice, ws7: ws7, ws9: ws9, scope7: scope7, scope9: scope9, daemon: daemon}
  end

  defp register(ctx, repos, protocol \\ HelmsmanProtocol.version()) do
    assert {:ok, _runtimes} =
             Daemons.register(ctx.daemon.id, ctx.daemon.auth_epoch, local_join(repos, protocol))
  end

  defp row(workspace, name),
    do:
      Repo.one(
        from(l in LocalRepository, where: l.workspace_id == ^workspace.id and l.name == ^name)
      )

  test "a repository is registered only in the workspaces it is shared with (scenario)", ctx do
    register(ctx, [local_report("app", [ctx.ws7.id])])

    assert %LocalRepository{
             status: "online",
             default_branch: "main",
             path: "/home/alice/code/app"
           } =
             app = row(ctx.ws7, "app")

    assert app.daemon_id == ctx.daemon.id
    assert row(ctx.ws9, "app") == nil
    assert {:ok, []} = LocalRepositories.list(ctx.scope9)

    project = project_fixture(ctx.scope9)
    assert {:error, :not_found} = Projects.bind_local_repository(ctx.scope9, project.key, app.id)
  end

  test "only workspaces the daemon serves validly are registered", ctx do
    other = workspace_fixture(user_fixture())
    {:ok, _} = Daemons.set_workspaces(ctx.scope7, ctx.daemon.id, [ctx.ws7.id])

    register(ctx, [local_report("app", [ctx.ws7.id, ctx.ws9.id, other.id])])

    assert row(ctx.ws7, "app")
    assert row(ctx.ws9, "app") == nil
    assert row(other, "app") == nil
  end

  test "an unavailable repository is registered with its reason", ctx do
    register(ctx, [
      local_report("app", [ctx.ws7.id], %{
        available: false,
        unavailable_reason: "not a git repository",
        default_branch: nil
      })
    ])

    assert %LocalRepository{status: "unavailable", unavailable_reason: "not a git repository"} =
             row(ctx.ws7, "app")

    register(ctx, [local_report("app", [ctx.ws7.id])])
    assert %LocalRepository{status: "online", unavailable_reason: nil} = row(ctx.ws7, "app")
  end

  test "removed on the machine: unavailable, the binding stays (scenario)", ctx do
    register(ctx, [local_report("app", [ctx.ws7.id]), local_report("lib", [ctx.ws7.id])])
    project = project_fixture(ctx.scope7, %{key: "BOS"})
    {:ok, _} = Projects.bind_local_repository(ctx.scope7, "BOS", row(ctx.ws7, "app").id)

    register(ctx, [local_report("lib", [ctx.ws7.id])])

    assert %LocalRepository{
             status: "unavailable",
             unavailable_reason: "not configured on the machine"
           } =
             app = row(ctx.ws7, "app")

    assert Repo.reload!(project).local_repository_id == app.id
    assert row(ctx.ws7, "lib").status == "online"
  end

  test "sharing revoked: unavailable with the reason, the binding stays (scenario)", ctx do
    register(ctx, [local_report("app", [ctx.ws7.id, ctx.ws9.id])])
    project = project_fixture(ctx.scope7, %{key: "BOS"})
    {:ok, _} = Projects.bind_local_repository(ctx.scope7, "BOS", row(ctx.ws7, "app").id)

    register(ctx, [local_report("app", [ctx.ws9.id])])

    assert %LocalRepository{
             status: "unavailable",
             unavailable_reason: "not shared with this workspace on the machine"
           } = app = row(ctx.ws7, "app")

    assert row(ctx.ws9, "app").status == "online"

    assert {:ok, %{local_repository: %{id: id, status: "unavailable"}}} =
             Projects.get(ctx.scope7, "BOS")

    assert id == app.id
    assert Repo.reload!(project).local_repository_id == app.id
  end

  test "a name reported twice is unavailable", ctx do
    register(ctx, [local_report("app", [ctx.ws7.id]), local_report("app", [ctx.ws7.id])])

    assert %LocalRepository{
             status: "unavailable",
             unavailable_reason: "duplicate name on the machine"
           } =
             row(ctx.ws7, "app")
  end

  test "members see name, machine, owner and status but not the path (scenario)", ctx do
    register(ctx, [local_report("app", [ctx.ws7.id])])
    {_bob, member_scope} = member_scope_fixture(ctx.ws7, :member)
    {_carol, admin_scope} = member_scope_fixture(ctx.ws7, :admin)

    assert {:ok, [view]} = LocalRepositories.list(member_scope)
    assert %{name: "app", daemon_name: "alice-mbp", status: "online", path: nil} = view
    assert view.owner.user_id == ctx.alice.id

    for scope <- [admin_scope, ctx.scope7] do
      assert {:ok, [%{path: "/home/alice/code/app"}]} = LocalRepositories.list(scope)
    end

    # The daemon's owner sees the path even as a plain member.
    {dave, dave_scope} = member_scope_fixture(ctx.ws7, :member)
    {other_daemon, _} = daemon_fixture(dave, %{workspace_ids: [ctx.ws7.id], name: "dave-pc"})

    assert {:ok, _} =
             Daemons.register(
               other_daemon.id,
               other_daemon.auth_epoch,
               local_join([local_report("tools", [ctx.ws7.id])])
             )

    assert {:ok, views} = LocalRepositories.list(dave_scope)

    assert %{"app" => nil, "tools" => "/home/alice/code/tools"} ==
             Map.new(views, &{&1.name, &1.path})

    assert {:ok, %{local_repository: %{path: nil}}} = project_view(ctx, member_scope)
  end

  test "MarkOffline sets online repositories offline with the runtimes", ctx do
    register(ctx, [
      local_report("app", [ctx.ws7.id]),
      local_report("bad", [ctx.ws7.id], %{available: false, unavailable_reason: "missing"})
    ])

    old = DateTime.add(Daemons.now(), -3_600)
    Repo.update_all(from(d in Daemon, where: d.id == ^ctx.daemon.id), set: [last_seen_at: old])
    :ok = Events.subscribe(Events.topic(:workspace, ctx.ws7.id))

    assert :ok = perform_job(MarkOffline, %{})
    assert row(ctx.ws7, "app").status == "offline"
    assert row(ctx.ws7, "bad").status == "unavailable"
    assert_receive {:local_repositories_changed}

    register(ctx, [local_report("app", [ctx.ws7.id])])
    assert row(ctx.ws7, "app").status == "online"
  end

  test "a protocol 1 join leaves local repositories as they are", ctx do
    register(ctx, [local_report("app", [ctx.ws7.id])])
    before = row(ctx.ws7, "app")

    register(ctx, nil, 1)
    register(ctx, [], 1)
    assert row(ctx.ws7, "app") == before
  end

  test "{:local_repositories_changed} after the commit, only when something changed", ctx do
    :ok = Events.subscribe(Events.topic(:workspace, ctx.ws7.id))
    :ok = Events.subscribe(Events.topic(:workspace, ctx.ws9.id))

    register(ctx, [local_report("app", [ctx.ws7.id])])
    assert_receive {:local_repositories_changed}
    refute_receive {:local_repositories_changed}, 50

    register(ctx, [local_report("app", [ctx.ws7.id])])
    refute_receive {:local_repositories_changed}, 50

    register(ctx, [local_report("app", [ctx.ws7.id], %{path: "/srv/app"})])
    assert_receive {:local_repositories_changed}
  end

  defp project_view(ctx, scope) do
    project_fixture(ctx.scope7, %{key: "VIEW"})
    {:ok, _} = Projects.bind_local_repository(ctx.scope7, "VIEW", row(ctx.ws7, "app").id)
    Projects.get(scope, "VIEW")
  end

  defp perform_job(worker, args), do: worker.perform(%Oban.Job{args: args})
end
