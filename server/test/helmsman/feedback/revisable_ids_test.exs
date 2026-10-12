defmodule Helmsman.Feedback.RevisableIdsTest do
  use Helmsman.DataCase, async: true

  import Helmsman.AccountsFixtures
  import Helmsman.ApiTokensFixtures
  import Helmsman.ProjectsFixtures
  import Helmsman.WorkspacesFixtures

  alias Helmsman.Actors
  alias Helmsman.Feedback

  setup do
    owner = user_fixture()
    workspace = workspace_fixture(owner)
    owner_scope = workspace_scope_fixture(owner, workspace)

    [alice, bob, viewer] =
      for role <- [:member, :member, :viewer] do
        user = user_fixture()
        member_fixture(workspace, user, role)
        workspace_scope_fixture(user, workspace)
      end

    project_fixture(owner_scope, key: "BOS")
    alice_dev = %{alice | actor: agent_fixture(workspace, alice.user, "alice/dev")}
    {:ok, system} = Repo.transact(fn -> Actors.ensure_system(workspace) end)
    task = task_fixture(alice, "BOS")

    %{
      workspace: workspace,
      owner: owner_scope,
      alice: alice,
      alice_dev: alice_dev,
      bob: bob,
      viewer: viewer,
      system: %{owner_scope | actor: system},
      task: task
    }
  end

  defp add!(scope, task) do
    {:ok, entry} = Feedback.add(scope, task.ident, %{kind: :comment, content: "Text"})
    Feedback.view(entry).id
  end

  test "the author, another identity of the same user; not others or the system", ctx do
    own = add!(ctx.alice, ctx.task)
    own_agent = add!(ctx.alice_dev, ctx.task)
    bobs = add!(ctx.bob, ctx.task)
    systems = add!(ctx.system, ctx.task)

    assert {:ok, ids} = Feedback.revisable_ids(ctx.alice, ctx.task.ident)
    assert ids == MapSet.new([own, own_agent])

    # The agent may revise its owner's record too.
    assert Feedback.revisable_ids(ctx.alice_dev, ctx.task.ident) == {:ok, ids}

    assert Feedback.revisable_ids(ctx.bob, ctx.task.ident) == {:ok, MapSet.new([bobs])}
    refute MapSet.member?(elem(Feedback.revisable_ids(ctx.owner, ctx.task.ident), 1), systems)
  end

  test "superseded records are left out", ctx do
    old = add!(ctx.alice, ctx.task)
    {:ok, revised} = Feedback.revise(ctx.alice, old, %{content: "Better"})
    new = Feedback.view(revised).id

    assert Feedback.revisable_ids(ctx.alice, String.downcase(ctx.task.ident)) ==
             {:ok, MapSet.new([new])}
  end

  test "a viewer gets an empty set", ctx do
    add!(ctx.alice, ctx.task)
    assert Feedback.revisable_ids(ctx.viewer, ctx.task.ident) == {:ok, MapSet.new()}
  end

  test "tasks of other workspaces and unknown tasks are not found", ctx do
    stranger = user_fixture()
    other = workspace_fixture(stranger)
    other_scope = workspace_scope_fixture(stranger, other)

    assert Feedback.revisable_ids(other_scope, ctx.task.ident) == {:error, :not_found}
    assert Feedback.revisable_ids(ctx.alice, "BOS-999") == {:error, :not_found}
    assert Feedback.revisable_ids(ctx.alice, "nonsense") == {:error, :not_found}
  end

  test "at most two queries", ctx do
    for _ <- 1..5, do: add!(ctx.alice, ctx.task)
    parent = self()
    id = {__MODULE__, make_ref()}

    :telemetry.attach(
      id,
      [:helmsman, :repo, :query],
      fn _event, _measurements, _metadata, _config ->
        if self() == parent, do: send(parent, :query)
      end,
      nil
    )

    assert {:ok, ids} = Feedback.revisable_ids(ctx.alice, ctx.task.ident)
    :telemetry.detach(id)

    assert MapSet.size(ids) == 5
    assert_received :query
    assert_received :query
    refute_received :query
  end
end
