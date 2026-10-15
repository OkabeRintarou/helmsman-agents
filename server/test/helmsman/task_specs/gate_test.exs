defmodule Helmsman.TaskSpecs.GateTest do
  # add-spec-workflow 1.5: the finalize gate, table-driven (pure).
  use ExUnit.Case, async: true

  alias Helmsman.TaskSpecs.Gate

  @ok %{
    status: :draft,
    latest_version: 3,
    validation: %{valid: true, errors: []},
    unresolved: [],
    pending: []
  }
  @errors [%{file: "tasks.md", line: nil, rule: "tasks_no_items", message: "x"}]

  # {name, changes, version, expected}
  @cases [
    {"everything holds", %{}, 3, :ok},
    {"in review without pending requests", %{status: :in_review}, 3, :ok},
    {"a proposal is waiting", %{status: :pending_approval}, 3, :ok},
    {"no version", %{latest_version: 0}, 1, {:spec, :no_version}},
    {"an older version", %{}, 2, {:spec, :stale_version, 3}},
    {"a newer version", %{}, 4, {:spec, :stale_version, 3}},
    {"no version given", %{}, nil, {:spec, :stale_version, 3}},
    {"finalized", %{status: :finalized}, 3, {:spec, :closed, :finalized}},
    {"abandoned", %{status: :abandoned}, 3, {:spec, :closed, :abandoned}},
    {"invalid", %{validation: %{valid: false, errors: @errors}}, 3, {:spec, :invalid, @errors}},
    {"unresolved", %{unresolved: ["R2.1", "R2.3"]}, 3,
     {:spec, :unresolved_issues, ["R2.1", "R2.3"]}},
    {"pending", %{pending: ["keel/review"]}, 3, {:spec, :reviews_pending, ["keel/review"]}},
    # Combinations: the first failing condition wins.
    {"stale before closed", %{status: :finalized}, 2, {:spec, :stale_version, 3}},
    {"closed before invalid", %{status: :abandoned, validation: %{valid: false, errors: @errors}},
     3, {:spec, :closed, :abandoned}},
    {"invalid before unresolved",
     %{validation: %{valid: false, errors: @errors}, unresolved: ["R1.1"]}, 3,
     {:spec, :invalid, @errors}},
    {"unresolved before pending", %{unresolved: ["R1.1"], pending: ["bob"]}, 3,
     {:spec, :unresolved_issues, ["R1.1"]}},
    {"everything wrong", %{status: :finalized, unresolved: ["R1.1"], pending: ["bob"]}, 1,
     {:spec, :stale_version, 3}}
  ]

  for {name, changes, version, expected} <- @cases do
    @changes changes
    @expected expected
    test name do
      expected = if @expected == :ok, do: :ok, else: {:error, @expected}
      assert Gate.check(Map.merge(@ok, @changes), unquote(version)) == expected
    end
  end
end
