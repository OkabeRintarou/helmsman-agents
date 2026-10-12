defmodule HelmsmanWeb.TaskLive.FilterTest do
  use ExUnit.Case, async: true

  alias HelmsmanWeb.TaskLive.Filter

  defp task(attrs) do
    Map.merge(
      %{status: "new", labels: ["api", "backend"], assignee: %{name: "alice", kind: "human"}},
      attrs
    )
  end

  test "empty filters match everything" do
    assert Filter.match?(task(%{}), %{})
  end

  test "status" do
    assert Filter.match?(task(%{}), %{status: ["new", "in_progress"]})
    refute Filter.match?(task(%{status: "done"}), %{status: ["new", "in_progress"]})
  end

  test "label" do
    assert Filter.match?(task(%{}), %{label: "api"})
    assert Filter.match?(task(%{}), %{label: " API "})
    refute Filter.match?(task(%{}), %{label: "ui"})
    refute Filter.match?(task(%{labels: []}), %{label: "api"})
  end

  test "assignee, including @none" do
    assert Filter.match?(task(%{}), %{assignee: "alice"})
    assert Filter.match?(task(%{}), %{assignee: "Alice"})
    refute Filter.match?(task(%{}), %{assignee: "bob"})
    refute Filter.match?(task(%{}), %{assignee: "@none"})
    assert Filter.match?(task(%{assignee: nil}), %{assignee: "@none"})
    refute Filter.match?(task(%{assignee: nil}), %{assignee: "alice"})
  end

  test "all dimensions together" do
    filters = %{status: ["new"], label: "api", assignee: "alice"}
    assert Filter.match?(task(%{}), filters)
    refute Filter.match?(task(%{status: "done"}), filters)
  end

  test "domain options and quick views" do
    assert Filter.domain_opts(%{assignee: "@none", label: "api"}) == [label: "api", assignee: ""]
    assert Filter.domain_opts(%{}) == []

    assert Filter.current_view(%{}) == :all
    assert Filter.current_view(%{status: ["done", "new", "in_progress"]}) == :open
    assert Filter.current_view(%{status: ~w(verified rejected cancelled)}) == :closed
    assert Filter.current_view(%{status: ["new"]}) == nil
  end
end
