defmodule Helmsman.Tasks.StateMachineTest do
  use ExUnit.Case, async: true

  alias Helmsman.Tasks.StateMachine

  doctest StateMachine

  @statuses [:new, :in_progress, :done, :verified, :rejected, :cancelled]

  # The transition table of the task-status spec.
  @table %{
    new: [:in_progress, :rejected, :cancelled],
    in_progress: [:done, :rejected, :cancelled],
    done: [:verified, :in_progress],
    verified: [:in_progress],
    rejected: [:new],
    cancelled: [:new]
  }

  @ctx %{
    blockers: [],
    replaced_by: [],
    active_run: nil,
    self_verify?: false,
    has_passing_tests?: false,
    assignee_name: nil
  }

  describe "check/3 with an empty context" do
    for from <- @statuses, to <- @statuses do
      @from from
      @to to
      test "#{from} → #{to}" do
        allowed = @table[@from]
        assert StateMachine.allowed(@from) == allowed

        if @to in allowed do
          assert StateMachine.check(@from, @to, @ctx) == :ok
        else
          assert StateMachine.check(@from, @to, @ctx) ==
                   {:error, {:invalid_transition, @from, @to, allowed}}
        end
      end
    end
  end

  describe "normalize/1" do
    test "accepts any case, blanks, spaces, dashes and the aliases" do
      for {input, status} <- [
            {"In Progress", :in_progress},
            {"in-progress", :in_progress},
            {"IN_PROGRESS", :in_progress},
            {"reject", :rejected},
            {"canceled", :cancelled},
            {" done ", :done},
            {"Verified", :verified},
            {:new, :new}
          ] do
        assert StateMachine.normalize(input) == {:ok, status}, inspect(input)
      end
    end

    test "rejects anything else, listing the six statuses" do
      for input <- ["doing", "", "in__progress", nil, 1, :doing] do
        assert StateMachine.normalize(input) == {:error, {:invalid_status, input, @statuses}}
      end
    end
  end

  describe "check/3 extra checks" do
    test "unmet dependencies block new → in_progress only" do
      ctx = %{@ctx | blockers: ["BOS-2"]}
      assert StateMachine.check(:new, :in_progress, ctx) == {:error, {:blocked, ["BOS-2"]}}
      assert StateMachine.check(:new, :cancelled, ctx) == :ok
    end

    test "a replacement blocks cancelled → new only" do
      ctx = %{@ctx | replaced_by: ["BOS-3"]}
      assert StateMachine.check(:cancelled, :new, ctx) == {:error, {:replaced, ["BOS-3"]}}
      assert StateMachine.check(:rejected, :new, ctx) == :ok
    end

    test "another active run blocks done → verified" do
      ctx = %{@ctx | active_run: %{id: 7}}
      assert StateMachine.check(:done, :verified, ctx) == {:error, {:run_active, %{id: 7}}}
      assert StateMachine.check(:done, :in_progress, ctx) == :ok
    end

    test "the assignee verifying needs passing tests" do
      ctx = %{@ctx | self_verify?: true, assignee_name: "keel/dev"}

      assert StateMachine.check(:done, :verified, ctx) ==
               {:error, {:self_verify_requires_tests, "keel/dev"}}

      assert StateMachine.check(:done, :verified, %{ctx | has_passing_tests?: true}) == :ok
    end

    test "someone else verifying needs no tests" do
      assert StateMachine.check(:done, :verified, %{@ctx | assignee_name: "keel/dev"}) == :ok
    end

    test "the transition table is checked first" do
      ctx = %{@ctx | blockers: ["BOS-2"], self_verify?: true}

      assert StateMachine.check(:done, :cancelled, ctx) ==
               {:error, {:invalid_transition, :done, :cancelled, [:verified, :in_progress]}}
    end
  end
end
