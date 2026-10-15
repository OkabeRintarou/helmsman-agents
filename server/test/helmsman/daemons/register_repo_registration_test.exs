defmodule Helmsman.Daemons.RegisterRepoRegistrationTest do
  # add-local-repo-web-registration 3.2: `Daemons.register/3` records
  # whether the daemon allows web registration (D8).
  use Helmsman.DataCase, async: true

  import Helmsman.AccountsFixtures
  import Helmsman.AgentsFixtures
  import Helmsman.LocalRepositoriesFixtures
  import Helmsman.WorkspacesFixtures

  alias Helmsman.{Daemons, Events}
  alias Helmsman.Daemons.Daemon
  alias HelmsmanProtocol.Report

  @v HelmsmanProtocol.repo_registration_version()

  setup do
    alice = user_fixture()
    workspace = workspace_fixture(alice)
    {daemon, _token} = daemon_fixture(alice, %{workspace_ids: [workspace.id]})
    %{alice: alice, daemon: daemon}
  end

  defp do_join(ctx, value, protocol \\ @v) do
    report = %{local_join([], protocol) | repo_registration: value}
    assert {:ok, _} = Daemons.register(ctx.daemon.id, ctx.daemon.auth_epoch, report)
    Repo.get!(Daemon, ctx.daemon.id).repo_registration
  end

  defp sync(ctx, value) do
    join = local_join([])

    report = %Report.Sync{
      machine: join.machine,
      clis: [],
      max_concurrency: 4,
      local_repositories: [],
      repo_registration: value
    }

    assert {:ok, _} = Daemons.register(ctx.daemon.id, ctx.daemon.auth_epoch, report)
    Repo.get!(Daemon, ctx.daemon.id).repo_registration
  end

  test "a protocol 7 join records the reported value", ctx do
    assert do_join(ctx, true)
    refute do_join(ctx, false)
    assert do_join(ctx, true)
    refute do_join(ctx, nil)
  end

  test "a sync records the reported value", ctx do
    assert sync(ctx, true)
    refute sync(ctx, nil)
    assert sync(ctx, true)
    refute sync(ctx, false)
  end

  test "an older protocol's join records false", ctx do
    assert do_join(ctx, true)
    refute do_join(ctx, nil, @v - 1)
    refute do_join(ctx, true, @v - 1)
  end

  test "a change tells the user's runtimes page; an unchanged value adds nothing", ctx do
    :ok = Events.subscribe(Events.topic(:user, ctx.alice.id))

    assert do_join(ctx, true)
    assert_receive {:daemons_changed}
    refute_receive {:daemons_changed}, 50

    # Every join already tells the page once (machine, version, last seen);
    # an unchanged value does not add a second message.
    assert do_join(ctx, true)
    assert_receive {:daemons_changed}
    refute_receive {:daemons_changed}, 50
  end
end
