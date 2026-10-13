defmodule Helmsman.LinksTest do
  use Helmsman.DataCase, async: true

  import Helmsman.LinksFixtures
  import Helmsman.ProjectsFixtures

  alias Helmsman.Links
  alias Helmsman.Links.Link
  alias Helmsman.Tasks

  setup do
    ctx = links_fixture()
    bos = tasks!(ctx.alice, "BOS", 3)
    web = tasks!(ctx.alice, "WEB", 2)
    Map.merge(ctx, %{bos: bos, web: web})
  end

  defp links, do: Repo.all(from(l in Link, order_by: [l.from_task_id, l.to_task_id, l.type]))

  defp detail(scope, ident) do
    {:ok, task} = Tasks.get(scope, ident)
    Tasks.detail(task)
  end

  describe "adding and removing (task-links: 建立与删除关联)" do
    test "a link to an epic has kind epic (add-epics decision 11)", %{alice: alice} do
      epic = task_fixture(alice, "BOS", %{kind: "epic"})

      assert {:ok, %{links: [%{task: ident, kind: "epic"}]}} =
               Links.add(alice, "WEB-1", epic.ident, "depends_on")

      assert ident == epic.ident
      assert [%{direction: "in", task: "WEB-1", kind: "task"}] = detail(alice, epic.ident).links
    end

    test "a cross-project dependency", %{alice: alice} do
      assert {:ok, %{id: "WEB-2", links: [link]}} =
               Links.add(alice, "web-2", "BOS-1", "depends_on")

      assert %{type: "depends_on", direction: "out", task: "BOS-1", status: "new"} = link
      assert link.kind == "task"
      assert link.actor == %{name: alice.actor.name, kind: "human"}
      assert %DateTime{} = link.created_at

      assert [%{type: "depends_on", direction: "in", task: "WEB-2"}] =
               detail(alice, "BOS-1").links
    end

    test "adding again succeeds and changes nothing", %{alice: alice} do
      {:ok, _} = Links.add(alice, "WEB-2", "BOS-1", "depends_on")
      [before] = links()

      assert {:ok, %{links: [_]}} = Links.add(alice, "WEB-2", "BOS-1", "depends-on")
      assert links() == [before]
    end

    test "the same pair may have both types", %{alice: alice} do
      {:ok, _} = Links.add(alice, "BOS-1", "BOS-2", "depends_on")
      {:ok, detail} = Links.add(alice, "BOS-1", "BOS-2", "replaces")

      assert [{"out", "depends_on", "BOS-2"}, {"out", "replaces", "BOS-2"}] =
               Enum.map(detail.links, &{&1.direction, &1.type, &1.task})

      assert length(links()) == 2
    end

    test "type spellings", %{alice: alice} do
      for {input, type} <- [
            {"Depends-On", :depends_on},
            {" depends on ", :depends_on},
            {"DEPENDS_ON", :depends_on},
            {:replaces, :replaces},
            {"Replaces", :replaces}
          ] do
        assert Links.normalize_type(input) == {:ok, type}
      end

      assert {:ok, _} = Links.add(alice, "BOS-1", "BOS-2", "Depends On")
      assert [%Link{type: :depends_on}] = links()
    end

    test "an unknown type", %{alice: alice} do
      assert Links.add(alice, "BOS-1", "BOS-2", "relates") ==
               {:error, {:invalid_type, "relates"}}

      assert Links.remove(alice, "BOS-1", "BOS-2", nil) == {:error, {:invalid_type, nil}}
      assert links() == []
    end

    test "a self link", %{alice: alice} do
      assert Links.add(alice, "BOS-1", "bos-1", "depends_on") == {:error, :self_link}
      assert Links.remove(alice, "BOS-1", "bos-1", "replaces") == {:error, :self_link}
    end

    test "not_found names the missing end", %{alice: alice} do
      assert Links.add(alice, "BOS-1", "BOS-99", "replaces") == {:error, {:not_found, "BOS-99"}}
      assert Links.add(alice, "bos-99", "BOS-1", "replaces") == {:error, {:not_found, "BOS-99"}}
      assert Links.add(alice, "BOS-98", "BOS-99", "replaces") == {:error, {:not_found, "BOS-98"}}
      assert Links.add(alice, "BOS-1", "nope", "replaces") == {:error, {:not_found, "NOPE"}}

      assert Links.remove(alice, "BOS-1", "BOS-99", "replaces") ==
               {:error, {:not_found, "BOS-99"}}
    end

    test "a task of another workspace is not found", %{alice: alice} do
      other = links_fixture()
      # BOS-4 exists in the other workspace only.
      tasks!(other.alice, "BOS", 4)
      assert Links.add(alice, "BOS-1", "BOS-4", "depends_on") == {:error, {:not_found, "BOS-4"}}
    end

    test "a viewer is refused; a member's agent may", %{viewer: viewer, keel: keel} do
      assert Links.add(viewer, "BOS-1", "BOS-2", "depends_on") == {:error, :forbidden}
      assert Links.remove(viewer, "BOS-1", "BOS-2", "depends_on") == {:error, :forbidden}

      assert {:ok, %{links: [%{actor: %{name: "keel/dev", kind: "agent"}}]}} =
               Links.add(keel, "BOS-1", "BOS-2", "depends_on")
    end

    test "a scope without an identity", %{alice: alice} do
      assert Links.add(%{alice | actor: nil}, "BOS-1", "BOS-2", "depends_on") ==
               {:error, :no_actor}
    end

    test "removing", %{alice: alice} do
      {:ok, _} = Links.add(alice, "WEB-2", "BOS-1", "depends_on")
      {:ok, _} = Links.add(alice, "WEB-2", "BOS-1", "replaces")

      assert {:ok, %{links: [%{type: "replaces"}]}} =
               Links.remove(alice, "web-2", "bos-1", "depends on")

      assert [%Link{type: :replaces}] = links()
    end

    test "removing a link that does not exist succeeds", %{alice: alice} do
      assert {:ok, %{id: "BOS-1", links: []}} = Links.remove(alice, "BOS-1", "BOS-2", "replaces")
    end

    test "removing changes no status", %{alice: alice, bos: [b1, b2 | _]} do
      {:ok, _} = Tasks.transition(alice, b2.ident, "in_progress")
      {:ok, _} = Links.add(alice, "BOS-1", "BOS-2", "replaces")
      assert status_of(b2) == :cancelled

      {:ok, _} = Links.remove(alice, "BOS-1", "BOS-2", "replaces")
      assert status_of(b2) == :cancelled
      assert status_of(b1) == :new
    end
  end

  describe "cycles (task-links: 依赖不能成环)" do
    test "a cycle is refused with its path", %{alice: alice} do
      {:ok, _} = Links.add(alice, "BOS-2", "BOS-3", "depends_on")
      {:ok, _} = Links.add(alice, "BOS-3", "BOS-1", "depends_on")
      before = links()

      assert Links.add(alice, "BOS-1", "BOS-2", "depends_on") ==
               {:error, {:cycle, ["BOS-1", "BOS-2", "BOS-3", "BOS-1"]}}

      assert links() == before
    end

    test "a two-task cycle", %{alice: alice} do
      {:ok, _} = Links.add(alice, "BOS-1", "WEB-1", "depends_on")

      assert Links.add(alice, "web-1", "bos-1", "depends_on") ==
               {:error, {:cycle, ["WEB-1", "BOS-1", "WEB-1"]}}
    end

    test "the shortest path is reported", %{alice: alice} do
      # BOS-2 → BOS-3 → WEB-1 → BOS-1 and BOS-2 → BOS-1
      {:ok, _} = Links.add(alice, "BOS-2", "BOS-3", "depends_on")
      {:ok, _} = Links.add(alice, "BOS-3", "WEB-1", "depends_on")
      {:ok, _} = Links.add(alice, "WEB-1", "BOS-1", "depends_on")
      {:ok, _} = Links.add(alice, "BOS-2", "BOS-1", "depends_on")

      assert Links.add(alice, "BOS-1", "BOS-2", "depends_on") ==
               {:error, {:cycle, ["BOS-1", "BOS-2", "BOS-1"]}}
    end

    test "a diamond is not a cycle; replaces links do not count", %{alice: alice} do
      {:ok, _} = Links.add(alice, "BOS-1", "BOS-2", "depends_on")
      {:ok, _} = Links.add(alice, "BOS-1", "BOS-3", "depends_on")
      {:ok, _} = Links.add(alice, "BOS-2", "WEB-1", "depends_on")
      assert {:ok, _} = Links.add(alice, "BOS-3", "WEB-1", "depends_on")

      {:ok, _} = Links.add(alice, "WEB-2", "BOS-1", "replaces")
      assert {:ok, _} = Links.add(alice, "BOS-1", "WEB-2", "depends_on")
    end
  end
end

defmodule Helmsman.LinksRaceTest do
  # Each request runs on a connection of its own outside the sandbox.
  use ExUnit.Case, async: false

  import Helmsman.AccountsFixtures
  import Helmsman.ProjectsFixtures
  import Helmsman.WorkspacesFixtures

  alias Helmsman.{CommittedData, LockHarness, Repo}
  alias Helmsman.Links

  setup do
    tag = System.unique_integer([:positive])

    {owner, scope} =
      CommittedData.unboxed(fn ->
        owner = user_fixture(%{email: "owner-#{tag}@links-race.test"})
        workspace = workspace_fixture(owner)
        scope = workspace_scope_fixture(owner, workspace)
        project_fixture(scope, key: "BOS")
        task_fixture(scope, "BOS")
        task_fixture(scope, "BOS")
        {owner, scope}
      end)

    on_exit(fn -> CommittedData.delete_user_data!([owner.id]) end)
    %{scope: scope}
  end

  test "two requests that would form a cycle together: exactly one succeeds", %{scope: scope} do
    first =
      LockHarness.start(fn -> Links.add(scope, "BOS-1", "BOS-2", "depends_on") end,
        pause: :link_checked
      )

    LockHarness.await_paused(first)

    second = LockHarness.start(fn -> Links.add(scope, "BOS-2", "BOS-1", "depends_on") end)
    LockHarness.await_blocked(second)

    # The second waits for the graph lock the first holds (an advisory lock).
    assert %{rows: [[1]]} =
             CommittedData.unboxed(fn ->
               Repo.query!(
                 "SELECT count(*)::int FROM pg_locks " <>
                   "WHERE pid = $1 AND locktype = 'advisory' AND NOT granted",
                 [second.backend]
               )
             end)

    LockHarness.continue(first)

    assert {:ok, %{id: "BOS-1"}} = LockHarness.result(first)

    assert LockHarness.result(second) ==
             {:error, {:cycle, ["BOS-2", "BOS-1", "BOS-2"]}}

    assert %{rows: [[1]]} =
             CommittedData.unboxed(fn ->
               Repo.query!("SELECT count(*)::int FROM task_links WHERE workspace_id = $1", [
                 scope.workspace.id
               ])
             end)
  end
end
