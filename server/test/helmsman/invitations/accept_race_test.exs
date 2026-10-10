defmodule Helmsman.Invitations.AcceptRaceTest do
  # Each accept commits on a connection of its own outside the sandbox.
  use ExUnit.Case, async: false

  import Ecto.Query
  import Helmsman.AccountsFixtures
  import Helmsman.WorkspacesFixtures

  alias Helmsman.CommittedData
  alias Helmsman.Invitations
  alias Helmsman.Repo
  alias Helmsman.Workspaces.Membership

  setup do
    tag = System.unique_integer([:positive])

    {users, workspace, token} =
      CommittedData.unboxed(fn ->
        owner = user_fixture(%{email: "owner-#{tag}@accept-race.test"})
        carol = user_fixture(%{email: "carol-#{tag}@accept-race.test"})
        dave = user_fixture(%{email: "dave-#{tag}@accept-race.test"})
        workspace = workspace_fixture(owner)
        %{token: token} = invitation_fixture(workspace_scope_fixture(owner, workspace))
        {[owner, carol, dave], workspace, token}
      end)

    on_exit(fn -> CommittedData.delete_user_data!(Enum.map(users, & &1.id)) end)

    [_owner, carol, dave] = users
    %{carol: carol, dave: dave, workspace: workspace, token: token}
  end

  test "two users accepting the same invitation at once: exactly one joins",
       %{carol: carol, dave: dave, workspace: ws, token: token} do
    parent = self()

    tasks =
      for user <- [carol, dave] do
        Task.async(fn ->
          CommittedData.unboxed(fn ->
            send(parent, {:ready, self()})

            receive do
              :go -> Invitations.accept(user, token)
            end
          end)
        end)
      end

    # Barrier: both connections are checked out before either accepts.
    for _ <- tasks, do: assert_receive({:ready, _pid}, 5_000)
    Enum.each(tasks, &send(&1.pid, :go))

    results = Task.await_many(tasks, 10_000)

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.count(results, &(&1 == {:error, :invalid_invitation})) == 1

    members =
      CommittedData.unboxed(fn ->
        Repo.aggregate(from(m in Membership, where: m.workspace_id == ^ws.id), :count)
      end)

    # The owner plus the one who got in.
    assert members == 2
  end
end
