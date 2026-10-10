defmodule Helmsman.Actors.EnsureHumanRaceTest do
  # Two joins commit concurrently on their own connections outside the
  # sandbox.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Helmsman.AccountsFixtures
  import Helmsman.WorkspacesFixtures

  alias Helmsman.Actors
  alias Helmsman.CommittedData
  alias Helmsman.Repo
  alias Helmsman.Tx
  alias Helmsman.Workspaces.Membership

  setup do
    tag = System.unique_integer([:positive])

    {owner, joiners, workspace} =
      CommittedData.unboxed(fn ->
        owner = user_fixture(%{email: "owner-#{tag}@race.test"})
        joiners = for d <- ["a", "b"], do: user_fixture(%{email: "alice@#{d}-#{tag}.test"})
        {owner, joiners, workspace_fixture(owner)}
      end)

    on_exit(fn -> CommittedData.delete_user_data!([owner.id | Enum.map(joiners, & &1.id)]) end)

    %{joiners: joiners, workspace: workspace}
  end

  test "two users with the same base name join at the same time",
       %{joiners: joiners, workspace: ws} do
    parent = self()

    {results, log} =
      with_log([level: :debug], fn ->
        tasks = for user <- joiners, do: Task.async(fn -> join(parent, ws, user) end)

        racers =
          for _ <- tasks do
            assert_receive {:ready, pid}, 5_000
            pid
          end

        Enum.each(racers, &send(&1, :go))
        Task.await_many(tasks, 10_000)
      end)

    assert [{:ok, a}, {:ok, b}] = results
    assert Enum.sort([a.name, b.name]) == ["alice", "alice-2"]
    refute log =~ "current transaction is aborted"

    CommittedData.unboxed(fn ->
      for user <- joiners do
        assert Repo.get_by(Membership, workspace_id: ws.id, user_id: user.id)
        assert Actors.get_human(ws.id, user.id)
      end
    end)
  end

  # In one outer transaction: insert the membership, wait at the barrier,
  # then create the human identity.
  defp join(parent, ws, user) do
    CommittedData.unboxed(fn ->
      Tx.run(fn ->
        Repo.insert!(%Membership{workspace_id: ws.id, user_id: user.id, role: :member})
        send(parent, {:ready, self()})

        receive do
          :go -> Actors.ensure_human(ws, user)
        end
      end)
    end)
  end
end
