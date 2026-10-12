defmodule HelmsmanWeb.RunDataTest do
  @moduledoc "HelmsmanWeb.RunData (add-agents-runs-ui D2): the placeholders of domain-request-1."
  use HelmsmanWeb.ConnCase, async: true

  import Helmsman.AccountsFixtures
  import Helmsman.AgentsFixtures
  import Helmsman.RunsFixtures, only: [agent_actor: 2]
  import Helmsman.WorkspacesFixtures

  alias Helmsman.Policy
  alias HelmsmanWeb.RunData

  describe "agent views and permissions (R7)" do
    setup do
      _admin = user_fixture()
      alice = user_fixture()
      ws = workspace_fixture(alice)
      alice_scope = workspace_scope_fixture(alice, ws)
      managed_agent_fixture(alice_scope, %{name: "keel/dev"})

      scopes =
        for role <- [:admin, :member, :viewer], into: %{owner: alice_scope} do
          user = user_fixture()
          member_fixture(ws, user, role)
          {role, workspace_scope_fixture(user, ws)}
        end

      %{ws: ws, scopes: scopes, actor: agent_actor(ws, "keel/dev")}
    end

    test "the views carry workspace_id and actor_id", %{ws: ws, scopes: scopes} do
      assert {:ok, view} = RunData.agent(scopes.viewer, "keel/dev")
      assert view.workspace_id == ws.id
      assert Map.has_key?(view, :actor_id)
      assert {:ok, [listed]} = RunData.agents(scopes.viewer)
      assert listed.workspace_id == ws.id
    end

    test "the same answers as Policy for every role", %{scopes: scopes, actor: actor} do
      {:ok, view} = RunData.agent(scopes.owner, "keel/dev")

      for {who, scope} <- scopes do
        perms = RunData.agent_permissions(scope, view)

        assert perms.configure == (Policy.authorize(scope, :configure_agent, actor) == :ok),
               "#{who}"

        assert perms.administer == (Policy.authorize(scope, :administer_agent, actor) == :ok),
               "#{who}"
      end

      assert RunData.agent_permissions(scopes.owner, view) == %{configure: true, administer: true}

      assert RunData.agent_permissions(scopes.admin, view) == %{
               configure: false,
               administer: true
             }

      assert RunData.agent_permissions(scopes.member, view) == %{
               configure: false,
               administer: false
             }

      assert RunData.agent_permissions(scopes.viewer, view) == %{
               configure: false,
               administer: false
             }
    end

    test "a view of another workspace allows nothing", %{scopes: scopes} do
      {:ok, view} = RunData.agent(scopes.owner, "keel/dev")
      other = %{view | workspace_id: view.workspace_id + 1}

      for {_who, scope} <- scopes do
        assert RunData.agent_permissions(scope, other) == %{configure: false, administer: false}
      end
    end
  end

  describe "read_window/2 (D8a)" do
    # Pages of `size` over `items`, recording every cursor it is called with.
    defp pager(items, size) do
      test = self()

      fn cursor ->
        send(test, {:cursor, cursor})
        rest = if cursor, do: Enum.drop_while(items, &(&1.id <= cursor)), else: items
        page = Enum.take(rest, size)
        next = if length(rest) > size, do: List.last(page).id
        {:ok, %{items: page, total: length(items), next: next}}
      end
    end

    defp cursors do
      receive do
        {:cursor, c} -> [c | cursors()]
      after
        0 -> []
      end
    end

    defp items(n), do: Enum.map(1..n, &%{id: &1})

    test "reads full pages until the window is filled, the first without a cursor" do
      assert {:ok, got, 250, _first} = RunData.read_window(pager(items(250), 100), 150)
      assert Enum.map(got, & &1.id) == Enum.to_list(1..150)
      assert cursors() == [nil, 100]
    end

    test "stops when everything is read" do
      assert {:ok, got, 30, _} = RunData.read_window(pager(items(30), 100), 150)
      assert length(got) == 30
      assert cursors() == [nil]
    end

    test "drops duplicates between pages" do
      pages = %{nil => {[%{id: 1}, %{id: 2}], :b}, :b => {[%{id: 2}, %{id: 3}], nil}}

      fun = fn cursor ->
        {page, next} = pages[cursor]
        {:ok, %{items: page, total: 3, next: next}}
      end

      assert {:ok, got, 3, _} = RunData.read_window(fun, 10)
      assert Enum.map(got, & &1.id) == [1, 2, 3]
    end

    test "every refresh starts again from the first page" do
      fun = pager(items(120), 50)
      {:ok, _, _, _} = RunData.read_window(fun, 100)
      {:ok, _, _, _} = RunData.read_window(fun, 100)
      assert cursors() == [nil, 50, nil, 50]
    end
  end
end
