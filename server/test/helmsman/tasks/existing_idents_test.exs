defmodule Helmsman.Tasks.ExistingIdentsTest do
  use Helmsman.DataCase, async: true

  import Helmsman.AccountsFixtures
  import Helmsman.ProjectsFixtures
  import Helmsman.WorkspacesFixtures

  alias Helmsman.Tasks

  setup do
    owner = user_fixture()
    scope = workspace_scope_fixture(owner, workspace_fixture(owner))
    project_fixture(scope, key: "BOS", name: "Bosun")
    for _ <- 1..2, do: task_fixture(scope, "BOS")

    other_owner = user_fixture()
    other = workspace_scope_fixture(other_owner, workspace_fixture(other_owner))
    project_fixture(other, key: "OPS", name: "Ops")
    task_fixture(other, "OPS")

    %{scope: scope}
  end

  defp count_queries(fun) do
    test_pid = self()
    handler = "existing-idents-#{System.unique_integer()}"

    :telemetry.attach(
      handler,
      [:helmsman, :repo, :query],
      fn _event, _measurements, _meta, _config ->
        if self() == test_pid, do: send(test_pid, :query)
      end,
      nil
    )

    try do
      result = fun.()
      {result, count_received(0)}
    after
      :telemetry.detach(handler)
    end
  end

  defp count_received(n) do
    receive do
      :query -> count_received(n + 1)
    after
      0 -> n
    end
  end

  test "returns the existing IDs only", %{scope: scope} do
    assert Tasks.existing_idents(scope, ["BOS-1", "BOS-2", "BOS-3", "XYZ-1"]) ==
             MapSet.new(["BOS-1", "BOS-2"])
  end

  test "IDs of other workspaces are not returned", %{scope: scope} do
    assert Tasks.existing_idents(scope, ["OPS-1"]) == MapSet.new()
  end

  test "any case is matched and the canonical form returned", %{scope: scope} do
    assert Tasks.existing_idents(scope, ["bos-1", "Bos-2", "BOS-01", "bos"]) ==
             MapSet.new(["BOS-1", "BOS-2"])
  end

  test "one query for any number of IDs, none without well-formed IDs", %{scope: scope} do
    idents = for n <- 1..50, do: "bos-#{n}"
    assert {result, 1} = count_queries(fn -> Tasks.existing_idents(scope, idents) end)
    assert result == MapSet.new(["BOS-1", "BOS-2"])

    assert {result, 0} = count_queries(fn -> Tasks.existing_idents(scope, ["x", "BOS-0"]) end)
    assert result == MapSet.new()
  end
end
