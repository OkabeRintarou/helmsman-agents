defmodule Helmsman.DaemonsTest do
  use Helmsman.DataCase, async: false

  import Helmsman.AccountsFixtures
  import Helmsman.WorkspacesFixtures
  import Helmsman.AgentsFixtures

  alias Helmsman.{Daemons, Repo}
  alias Helmsman.Daemons.{DaemonWorkspace, Runtime}
  alias Helmsman.Events

  setup do
    tag = System.unique_integer([:positive])

    owner = user_fixture(%{email: "daemon-owner-#{tag}@test.invalid"})
    other = user_fixture(%{email: "daemon-other-#{tag}@test.invalid"})
    workspace = workspace_fixture(owner)
    other_workspace = workspace_fixture(other)
    scope = workspace_scope_fixture(owner, workspace)
    other_scope = workspace_scope_fixture(other, other_workspace)

    %{
      owner: owner,
      other: other,
      workspace: workspace,
      other_workspace: other_workspace,
      scope: scope,
      other_scope: other_scope
    }
  end

  test "token rotation keeps the prior token valid for 24 hours, then revocation invalidates both",
       %{owner: owner, workspace: workspace, scope: scope} do
    now = DateTime.utc_now(:second)
    Application.put_env(:helmsman, :daemon_clock, fn -> now end)

    on_exit(fn -> Application.delete_env(:helmsman, :daemon_clock) end)

    {daemon, original_token} = daemon_fixture(owner, %{workspace_ids: [workspace.id]})

    assert {:ok, rotated_token} = Daemons.rotate_token(daemon.id, daemon.auth_epoch)
    assert {:ok, authenticated} = Daemons.authenticate(original_token)
    assert authenticated.id == daemon.id
    assert {:ok, _} = Daemons.authenticate(rotated_token)

    Application.put_env(:helmsman, :daemon_clock, fn -> DateTime.add(now, 86_401) end)
    assert {:error, :unauthorized} = Daemons.authenticate(original_token)
    assert {:ok, _} = Daemons.authenticate(rotated_token)

    assert {:ok, revoked} = Daemons.revoke(scope, daemon.id)
    assert revoked.auth_epoch == daemon.auth_epoch + 1
    assert {:error, :unauthorized} = Daemons.authenticate(original_token)
    assert {:error, :unauthorized} = Daemons.authenticate(rotated_token)
  end

  test "a daemon owned by another user is indistinguishable from missing", %{
    other: other,
    scope: scope
  } do
    {daemon, _token} = daemon_fixture(other)

    assert {:error, :not_found} = Daemons.revoke(scope, daemon.id)
    assert {:error, :not_found} = Daemons.rename(scope, daemon.id, "renamed")
    assert {:error, :not_found} = Daemons.set_workspaces(scope, daemon.id, [])
  end

  test "set_workspaces rejects a workspace where the daemon owner is only a viewer",
       %{owner: owner, workspace: workspace, other_workspace: viewer_workspace, scope: scope} do
    member_fixture(viewer_workspace, owner, :viewer)

    {daemon, _token} = daemon_fixture(owner, %{workspace_ids: [workspace.id]})

    assert {:error, {:invalid_workspaces, [id]}} =
             Daemons.set_workspaces(scope, daemon.id, [viewer_workspace.id])

    assert id == viewer_workspace.id
    [listed] = Daemons.list_own(scope)
    assert listed.id == daemon.id
    assert Enum.map(listed.workspaces, & &1.id) == [workspace.id]
  end

  test "set_workspaces can clear every workspace and takes its online runtimes offline",
       %{owner: owner, workspace: workspace, scope: scope} do
    {daemon, _token} = daemon_fixture(owner, %{workspace_ids: [workspace.id]})
    runtime = runtime_fixture(workspace, daemon)
    :ok = Events.subscribe(Events.topic(:daemon, daemon.id))
    :ok = Events.subscribe(Events.topic(:workspace, workspace.id))

    assert {:ok, _} = Daemons.set_workspaces(scope, daemon.id, [])

    assert Repo.get!(Runtime, runtime.id).status == "offline"
    refute Repo.get_by(DaemonWorkspace, daemon_id: daemon.id, workspace_id: workspace.id)
    assert_received {:runtimes_changed}
    assert_received {:daemon_config_changed}
  end
end
