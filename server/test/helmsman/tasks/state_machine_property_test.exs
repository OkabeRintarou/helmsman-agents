defmodule Helmsman.Tasks.StateMachinePropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Helmsman.Tasks.StateMachine
  alias Helmsman.Tasks.Task

  @empty %{
    blockers: [],
    replaced_by: [],
    active_run: nil,
    self_verify?: false,
    has_passing_tests?: false,
    assignee_name: nil
  }

  defp status, do: member_of(Task.statuses())

  property "with an empty context, check/3 passes exactly the allowed transitions" do
    check all from <- status(), to <- status() do
      passes? = StateMachine.check(from, to, @empty) == :ok
      assert passes? == to in StateMachine.allowed(from)
    end
  end

  property "50 random legal steps from new stay within the six statuses" do
    check all choices <- list_of(integer(0..100), length: 50) do
      Enum.reduce(choices, :new, fn choice, from ->
        allowed = StateMachine.allowed(from)
        to = Enum.at(allowed, rem(choice, length(allowed)))

        assert StateMachine.check(from, to, @empty) == :ok
        assert to in Task.statuses()
        refute Enum.empty?(StateMachine.allowed(to))
        to
      end)
    end
  end
end
