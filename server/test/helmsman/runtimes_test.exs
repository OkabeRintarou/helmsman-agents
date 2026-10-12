defmodule Helmsman.RuntimesTest do
  use Helmsman.DataCase, async: true

  import Helmsman.AccountsFixtures
  import Helmsman.AgentsFixtures
  import Helmsman.WorkspacesFixtures

  alias Helmsman.{Events, Runtimes}

  setup do
    owner = user_fixture()
    workspace = workspace_fixture(owner)
    owner_scope = workspace_scope_fixture(owner, workspace)

    member = user_fixture()
    member_fixture(workspace, member, :member)

    {owner_daemon, _owner_token} = daemon_fixture(owner, %{workspace_ids: [workspace.id]})
    own_runtime = runtime_fixture(workspace, owner_daemon, %{status: "offline"})
    own_codex_runtime = runtime_fixture(workspace, owner_daemon, %{provider: "codex"})

    {member_daemon, _member_token} = daemon_fixture(member, %{workspace_ids: [workspace.id]})
    member_runtime = runtime_fixture(workspace, member_daemon, %{provider: "codex"})

    %{
      owner: owner,
      workspace: workspace,
      owner_scope: owner_scope,
      owner_daemon: owner_daemon,
      own_runtime: own_runtime,
      own_codex_runtime: own_codex_runtime,
      member_runtime: member_runtime
    }
  end

  test "list is owner scoped by default and all includes other members' runtimes",
       %{
         owner_scope: scope,
         owner: owner,
         own_runtime: own,
         own_codex_runtime: codex,
         member_runtime: member_runtime
       } do
    assert {:ok, own_rows} = Runtimes.list(scope)
    assert Enum.map(own_rows, & &1.id) |> Enum.sort() == Enum.sort([own.id, codex.id])
    refute Enum.any?(own_rows, &(&1.id == member_runtime.id))

    own_view = Enum.find(own_rows, &(&1.id == own.id))
    assert own_view.status == "offline"
    assert own_view.daemon.user == %{id: owner.id, name: owner.display_name}
    assert own_view.daemon.name == "test-machine"

    assert {:ok, all_rows} = Runtimes.list(scope, all: true)

    assert Enum.map(all_rows, & &1.id) |> Enum.sort() ==
             Enum.sort([own.id, codex.id, member_runtime.id])
  end

  test "list_bindable includes offline runtimes, filters by provider, and excludes disabled ones",
       %{owner_scope: scope, own_runtime: offline, own_codex_runtime: codex} do
    assert {:ok, bindable} = Runtimes.list_bindable(scope)
    assert Enum.map(bindable, & &1.id) |> Enum.sort() == [offline.id, codex.id] |> Enum.sort()
    assert Enum.find(bindable, &(&1.id == offline.id)).status == "offline"

    assert {:ok, claude_only} = Runtimes.list_bindable(scope, :claude)
    assert Enum.map(claude_only, & &1.id) == [offline.id]

    assert {:ok, _} = Runtimes.disable(scope, codex.id)
    assert {:ok, after_disable} = Runtimes.list_bindable(scope)
    assert Enum.map(after_disable, & &1.id) == [offline.id]
  end

  test "disable and enable notify both topics and keep the agent bound",
       %{owner_scope: scope, workspace: workspace, owner_daemon: daemon, own_runtime: runtime} do
    agent = managed_agent_fixture(scope, %{name: "runtime-bound-agent", runtime_id: runtime.id})
    Events.subscribe(Events.topic(:workspace, workspace.id))
    Events.subscribe(Events.topic(:daemon, daemon.id))

    assert {:ok, disabled} = Runtimes.disable(scope, runtime.id)
    assert disabled.disabled_at
    assert_received {:runtimes_changed}
    assert_received {:daemon_config_changed}
    assert {:ok, []} = Runtimes.list_bindable(scope, :claude)

    assert {:ok, rows} = Runtimes.list(scope)
    assert Enum.find(rows, &(&1.id == runtime.id)).agents == [agent.name]

    assert {:ok, enabled} = Runtimes.enable(scope, runtime.id)
    assert is_nil(enabled.disabled_at)
    assert_received {:runtimes_changed}
    assert_received {:daemon_config_changed}

    assert {:ok, bindable} = Runtimes.list_bindable(scope, :claude)
    assert Enum.any?(bindable, &(&1.id == runtime.id))
    assert {:ok, rows} = Runtimes.list(scope)
    assert Enum.find(rows, &(&1.id == runtime.id)).agents == [agent.name]
  end
end
