defmodule Helmsman.Invitations.AcceptExpiryTest do
  # The blocking transaction and the accept run on connections of their own
  # outside the sandbox. Each test waits for a real expiry (about 2 s).
  use ExUnit.Case, async: false

  import Ecto.Query
  import Helmsman.AccountsFixtures
  import Helmsman.WorkspacesFixtures

  alias Helmsman.Actors
  alias Helmsman.CommittedData
  alias Helmsman.Invitations
  alias Helmsman.Invitations.Invitation
  alias Helmsman.Repo
  alias Helmsman.Workspaces

  setup do
    tag = System.unique_integer([:positive])

    {owner, carol, workspace, invitation, token} =
      CommittedData.unboxed(fn ->
        owner = user_fixture(%{email: "owner-#{tag}@accept-expiry.test"})
        carol = user_fixture(%{email: "carol-#{tag}@accept-expiry.test"})
        workspace = workspace_fixture(owner)

        %{invitation: invitation, token: token} =
          invitation_fixture(workspace_scope_fixture(owner, workspace))

        # Valid when the accept starts, expired by the time its lock is free.
        expires_at = DateTime.add(DateTime.utc_now(:second), 2, :second)

        Repo.update_all(from(i in Invitation, where: i.id == ^invitation.id),
          set: [expires_at: expires_at]
        )

        {owner, carol, workspace, %{invitation | expires_at: expires_at}, token}
      end)

    on_exit(fn -> CommittedData.delete_user_data!([owner.id, carol.id]) end)

    %{carol: carol, workspace: workspace, invitation: invitation, token: token}
  end

  for {name, lock_sql} <- [
        {"the invitation row", "SELECT 1 FROM invitations WHERE id = $1 FOR UPDATE"},
        {"the accepting user's row", "SELECT 1 FROM users WHERE id = $1 FOR UPDATE"}
      ] do
    test "an invitation that expires while the accept waits for #{name} is refused", ctx do
      %{carol: carol, workspace: ws, invitation: invitation, token: token} = ctx
      id = if unquote(name) =~ "invitation", do: invitation.id, else: carol.id
      parent = self()

      blocker =
        Task.async(fn ->
          CommittedData.unboxed(fn ->
            Repo.transact(fn ->
              Repo.query!(unquote(lock_sql), [id])
              send(parent, :locked)

              receive do
                :release -> {:ok, :released}
              end
            end)
          end)
        end)

      assert_receive :locked, 5_000

      accept =
        Task.async(fn ->
          CommittedData.unboxed(fn ->
            send(parent, {:backend, CommittedData.backend_pid()})
            Invitations.accept(carol, token)
          end)
        end)

      assert_receive {:backend, backend}, 5_000
      :ok = CommittedData.await_lock_wait(backend)
      wait_until_after(invitation.expires_at)

      send(blocker.pid, :release)
      assert {:ok, :released} = Task.await(blocker)
      assert Task.await(accept) == {:error, :invalid_invitation}

      CommittedData.unboxed(fn ->
        refute Repo.get!(Invitation, invitation.id).accepted_at
        refute Workspaces.get_membership(ws.id, carol.id)
        refute Actors.get_human(ws.id, carol.id)
      end)
    end
  end

  # Waiting for wall-clock time to pass is the point of this test.
  defp wait_until_after(time) do
    unless DateTime.after?(DateTime.utc_now(), time) do
      Process.sleep(50)
      wait_until_after(time)
    end
  end
end
