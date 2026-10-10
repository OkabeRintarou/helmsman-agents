defmodule Helmsman.Tasks.ArchiveRaceTest do
  # Archiving and creating run on connections of their own outside the
  # sandbox.
  use ExUnit.Case, async: false

  import Helmsman.AccountsFixtures
  import Helmsman.ProjectsFixtures
  import Helmsman.WorkspacesFixtures

  alias Helmsman.CommittedData
  alias Helmsman.Projects
  alias Helmsman.Repo
  alias Helmsman.Tasks
  alias Helmsman.Tx

  setup do
    tag = System.unique_integer([:positive])

    {owner, scope} =
      CommittedData.unboxed(fn ->
        owner = user_fixture(%{email: "owner-#{tag}@archive-race.test"})
        workspace = workspace_fixture(owner)
        scope = workspace_scope_fixture(owner, workspace)
        project_fixture(scope, key: "BOS")
        {owner, scope}
      end)

    on_exit(fn -> CommittedData.delete_user_data!([owner.id]) end)
    %{scope: scope}
  end

  test "archive committed first: the creation gets project_archived", %{scope: scope} do
    CommittedData.unboxed(fn ->
      assert {:ok, _} = Projects.archive(scope, "BOS")
      assert Tasks.create(scope, "BOS", %{title: "T"}) == {:error, :project_archived}
      assert {:ok, %{task_seq: 0}} = Projects.get(scope, "BOS")
    end)
  end

  test "a creation holding the project row makes archiving wait", %{scope: scope} do
    parent = self()

    # Connection A stops right after allocating the number, holding the
    # project row lock, until the test lets it go on.
    creator =
      Task.async(fn ->
        CommittedData.unboxed(fn ->
          Process.put(:helmsman_test_hook, fn
            :seq_allocated ->
              send(parent, {:allocated, self()})

              receive do
                :continue -> :ok
              end

            _other ->
              :ok
          end)

          Tasks.create(scope, "BOS", %{title: "Held"})
        end)
      end)

    assert_receive {:allocated, creator_pid}, 5_000

    # Connection B times out on the row lock.
    error =
      assert_raise Postgrex.Error, fn ->
        CommittedData.unboxed(fn ->
          Tx.run(fn ->
            Repo.query!("SET LOCAL lock_timeout = '200ms'")
            Projects.archive(scope, "BOS")
          end)
        end)
      end

    assert error.postgres.code == :lock_not_available

    send(creator_pid, :continue)
    assert {:ok, %{ident: "BOS-1"}} = Task.await(creator, 5_000)

    CommittedData.unboxed(fn ->
      assert {:ok, %{archived_at: %DateTime{}, task_seq: 1}} = Projects.archive(scope, "BOS")
      assert {:ok, %{ident: "BOS-1", title: "Held"}} = Tasks.get(scope, "BOS-1")
    end)
  end
end
