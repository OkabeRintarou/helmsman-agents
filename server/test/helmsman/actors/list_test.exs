defmodule Helmsman.Actors.ListTest do
  use Helmsman.DataCase, async: true

  import Helmsman.AccountsFixtures
  import Helmsman.ApiTokensFixtures
  import Helmsman.WorkspacesFixtures

  alias Helmsman.Actors

  setup do
    owner = user_fixture()
    workspace = workspace_fixture(owner)
    alice = user_fixture()
    member_fixture(workspace, alice, :member)
    viewer = user_fixture()
    member_fixture(workspace, viewer, :viewer)

    %{
      workspace: workspace,
      alice: alice,
      viewer: workspace_scope_fixture(viewer, workspace),
      alice_name: Actors.get_human(workspace.id, alice.id).name
    }
  end

  test "a viewer lists the workspace's identities with agent owners", ctx do
    agent_fixture(ctx.workspace, ctx.alice, "keel/dev", %{project_key: "KEEL", worktree: "wt-1"})
    other = workspace_fixture(user_fixture())
    agent_fixture(other, ctx.alice, "other/dev")

    assert {:ok, actors} = Actors.list(ctx.viewer)
    names = Enum.map(actors, & &1.name)

    assert "keel/dev" in names and ctx.alice_name in names and "helmsman" in names
    refute "other/dev" in names
    assert Enum.map(actors, & &1.kind) == Enum.sort_by(Enum.map(actors, & &1.kind), &kind_rank/1)

    keel = Enum.find(actors, &(&1.name == "keel/dev"))

    assert %{kind: :agent, owner: owner, disabled: false, project: "KEEL", worktree: "wt-1"} =
             keel

    assert owner == ctx.alice_name
    assert %{kind: :system, owner: nil} = Enum.find(actors, &(&1.name == "helmsman"))
  end

  test "one query for many identities", ctx do
    for n <- 1..30, do: agent_fixture(ctx.workspace, ctx.alice, "bulk/agent-#{n}")
    id = {__MODULE__, make_ref()}
    parent = self()

    :telemetry.attach(
      id,
      [:helmsman, :repo, :query],
      fn _event, _measurements, _metadata, _config ->
        if self() == parent, do: send(parent, :query)
      end,
      nil
    )

    assert {:ok, actors} = Actors.list(ctx.viewer)
    :telemetry.detach(id)

    assert length(actors) >= 30
    assert_received :query
    refute_received :query
  end

  defp kind_rank(kind), do: Enum.find_index([:human, :agent, :squad, :system], &(&1 == kind))
end
