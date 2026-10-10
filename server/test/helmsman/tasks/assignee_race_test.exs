defmodule Helmsman.Tasks.AssigneeRaceTest do
  # Assigning a task to an agent races with removing the agent's owner,
  # which disables the agent. Each side runs on a connection of its own
  # outside the sandbox and is held open until the test lets it go on.
  use ExUnit.Case, async: false

  import Helmsman.AccountsFixtures
  import Helmsman.ProjectsFixtures
  import Helmsman.WorkspacesFixtures

  alias Helmsman.Actors.Actor
  alias Helmsman.CommittedData
  alias Helmsman.Events
  alias Helmsman.Members
  alias Helmsman.Projects
  alias Helmsman.Repo
  alias Helmsman.Tasks
  alias Helmsman.Tx

  setup do
    tag = System.unique_integer([:positive])

    # The owner removes bob; alice (a member, so the removal does not lock
    # her membership row) assigns tasks to bob's agent `dev`.
    {users, ctx} =
      CommittedData.unboxed(fn ->
        owner = user_fixture(%{email: "owner-#{tag}@assignee-race.test"})
        alice = user_fixture(%{email: "alice-#{tag}@assignee-race.test"})
        bob = user_fixture(%{email: "bob-#{tag}@assignee-race.test"})
        workspace = workspace_fixture(owner)
        member_fixture(workspace, alice, :member)
        bob_membership = member_fixture(workspace, bob, :member)

        Repo.insert!(%Actor{
          workspace_id: workspace.id,
          kind: :agent,
          name: "dev",
          owner_id: bob.id
        })

        owner_scope = workspace_scope_fixture(owner, workspace)
        project = project_fixture(owner_scope, key: "BOS")
        alice_scope = workspace_scope_fixture(alice, workspace)
        task_fixture(alice_scope, "BOS", title: "Existing")

        {[owner, alice, bob],
         %{
           owner: owner_scope,
           alice: alice_scope,
           bob_membership: bob_membership,
           project: project
         }}
      end)

    on_exit(fn -> CommittedData.delete_user_data!(Enum.map(users, & &1.id)) end)
    Events.subscribe(Events.topic(:project, ctx.project.id))
    ctx
  end

  defp create(scope), do: Tasks.create(scope, "BOS", %{title: "New", assignee: "dev"})
  defp edit(scope), do: Tasks.update(scope, "BOS-1", %{title: "Edited", assignee: "dev"}, 1)

  # Runs `fun` on its own connection; it reports its backend pid and, if
  # `hold_at` is a test hook point, stops there until told to continue.
  defp start(fun, hold_at \\ nil) do
    parent = self()

    Task.async(fn ->
      CommittedData.unboxed(fn ->
        Process.put(:helmsman_test_hook, &hold_at(&1, hold_at, parent))
        send(parent, {:backend, self(), CommittedData.backend_pid()})
        fun.()
      end)
    end)
  end

  defp hold_at(point, point, parent), do: hold(parent)
  defp hold_at(_point, _hold_at, _parent), do: :ok

  defp hold(parent) do
    send(parent, {:held, self()})

    receive do
      :continue -> :ok
    end
  end

  # Removes bob and stops before the commit.
  defp remove_bob_and_hold(ctx) do
    start(fn ->
      Tx.run(fn ->
        result = Members.remove(ctx.owner, ctx.bob_membership.id)
        hold(ctx.parent)
        result
      end)
    end)
  end

  defp backend(%Task{pid: pid}) do
    assert_receive {:backend, ^pid, backend}, 5_000
    backend
  end

  defp held(%Task{pid: pid}), do: assert_receive({:held, ^pid}, 5_000)

  defp dev_disabled? do
    CommittedData.unboxed(fn -> Repo.get_by!(Actor, name: "dev").disabled_at != nil end)
  end

  defp snapshot(ctx) do
    CommittedData.unboxed(fn ->
      {:ok, project} = Projects.get(ctx.owner, "BOS")
      {:ok, task} = Tasks.get(ctx.owner, "BOS-1")
      {project.task_seq, Tasks.detail(task)}
    end)
  end

  for {action, label} <- [create: "creating", edit: "editing"] do
    describe "#{label} a task assigned to an agent being disabled" do
      setup ctx, do: Map.put(ctx, :parent, self())

      test "disable holds the row first: the assignment waits, then fails", ctx do
        before = snapshot(ctx)
        remover = remove_bob_and_hold(ctx)
        backend(remover)
        held(remover)

        assigner = start(fn -> unquote(action)(ctx.alice) end)
        CommittedData.await_lock_wait(backend(assigner))

        send(remover.pid, :continue)
        assert {:ok, _} = Task.await(remover, 5_000)

        assert {:error, changeset} = Task.await(assigner, 5_000)
        assert {"is disabled", _} = changeset.errors[:assignee]
        assert snapshot(ctx) == before
        refute_receive {:task_created, _}
        refute_receive {:task_updated, _}
      end

      test "the assignment holds the row first: disabling waits for it", ctx do
        assigner = start(fn -> unquote(action)(ctx.alice) end, :assignee_locked)
        backend(assigner)
        held(assigner)

        remover = remove_bob_and_hold(ctx)
        CommittedData.await_lock_wait(backend(remover))
        refute dev_disabled?()

        send(assigner.pid, :continue)
        assert {:ok, task} = Task.await(assigner, 5_000)
        assert task.assignee.name == "dev"

        held(remover)
        send(remover.pid, :continue)
        assert {:ok, _} = Task.await(remover, 5_000)
        assert dev_disabled?()
      end
    end
  end
end
