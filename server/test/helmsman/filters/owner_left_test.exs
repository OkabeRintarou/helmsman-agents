defmodule Helmsman.Filters.OwnerLeftTest do
  use Helmsman.DataCase, async: true
  import Helmsman.AccountsFixtures
  import Helmsman.WorkspacesFixtures
  alias Helmsman.{Filters, Members}

  test "removal and voluntary leave delete private filters only in the affected workspace" do
    owner = user_fixture()
    workspace = workspace_fixture(owner)
    owner_scope = workspace_scope_fixture(owner, workspace)

    for action <- [:remove, :leave] do
      user = user_fixture()
      member = member_fixture(workspace, user, :member)
      scope = workspace_scope_fixture(user, workspace)
      other = workspace_fixture(user)
      other_scope = workspace_scope_fixture(user, other)
      assert {:ok, private} = Filters.create(scope, %{name: "private", bql: ""})

      assert {:ok, shared} =
               Filters.create(scope, %{name: "shared", bql: "", visibility: :workspace})

      assert {:ok, elsewhere} = Filters.create(other_scope, %{name: "elsewhere", bql: ""})

      result =
        if action == :remove,
          do: Members.remove(owner_scope, member.id),
          else: Members.leave(scope)

      assert {:ok, _} = result
      refute Repo.get(Helmsman.Filters.SavedFilter, private.id)
      assert {:ok, %{owner_left: true}} = Filters.get(owner_scope, shared.id)
      assert {:ok, %{owner_left: false}} = Filters.get(other_scope, elsewhere.id)
    end
  end
end
