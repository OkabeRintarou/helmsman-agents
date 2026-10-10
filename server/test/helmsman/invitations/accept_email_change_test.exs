defmodule Helmsman.Invitations.AcceptEmailChangeTest do
  # The email change and the accept run on connections of their own outside
  # the sandbox.
  use ExUnit.Case, async: false

  import Helmsman.AccountsFixtures
  import Helmsman.WorkspacesFixtures

  alias Helmsman.CommittedData
  alias Helmsman.Invitations
  alias Helmsman.Invitations.Invitation
  alias Helmsman.Repo
  alias Helmsman.Workspaces

  setup do
    tag = System.unique_integer([:positive])

    {owner, bob, workspace, invitation, token} =
      CommittedData.unboxed(fn ->
        owner = user_fixture(%{email: "owner-#{tag}@email-race.test"})
        bob = user_fixture(%{email: "bob-#{tag}@email-race.test"})
        workspace = workspace_fixture(owner)
        scope = workspace_scope_fixture(owner, workspace)
        %{invitation: invitation, token: token} = invitation_fixture(scope, email: bob.email)
        {owner, bob, workspace, invitation, token}
      end)

    on_exit(fn -> CommittedData.delete_user_data!([owner.id, bob.id]) end)

    %{bob: bob, workspace: workspace, invitation: invitation, token: token, tag: tag}
  end

  test "an accept waits for an uncommitted email change and then sees the new email",
       %{bob: bob, workspace: ws, invitation: invitation, token: token, tag: tag} do
    parent = self()

    change =
      Task.async(fn ->
        CommittedData.unboxed(fn ->
          Repo.transact(fn ->
            Repo.query!("UPDATE users SET email = $1 WHERE id = $2", [
              "eve-#{tag}@email-race.test",
              bob.id
            ])

            send(parent, :updated)

            receive do
              :commit -> {:ok, :committed}
            end
          end)
        end)
      end)

    assert_receive :updated, 5_000

    # `bob` is the struct from before the change, as an open page holds it.
    accept =
      Task.async(fn ->
        CommittedData.unboxed(fn ->
          send(parent, {:backend, CommittedData.backend_pid()})
          result = Invitations.accept(bob, token)
          {result, System.monotonic_time()}
        end)
      end)

    assert_receive {:backend, backend}, 5_000
    :ok = CommittedData.await_lock_wait(backend)

    committed_at = System.monotonic_time()
    send(change.pid, :commit)
    assert {:ok, :committed} = Task.await(change)

    {result, returned_at} = Task.await(accept)
    assert result == {:error, :email_mismatch}
    assert returned_at > committed_at

    CommittedData.unboxed(fn ->
      refute Repo.get!(Invitation, invitation.id).accepted_at
      refute Workspaces.get_membership(ws.id, bob.id)
    end)
  end
end
