defmodule Helmsman.Runs.TriggersTest do
  # add-continuation-triggers 1.6: the assignee binding (decision 8), now
  # `run_bound/1` and `bound_assignee/2` (add-squads decision 10);
  # add-dependency-dispatch 1.3: `dependency_gated?/1` and the neutral
  # `unblocked` marker (decision 3).
  use ExUnit.Case, async: true

  alias Helmsman.Runs.Triggers

  defp t(kind, extra \\ %{}), do: Map.merge(%{"kind" => kind}, extra)
  defp auto_retry, do: t("retry", %{"auto" => true, "retry_of" => 1})
  defp manual_retry, do: t("retry", %{"auto" => false, "retry_of" => 1})
  defp answer(bound), do: t("answer", %{"assignee_bound" => bound})

  for {name, triggers, expected} <- [
        {"[assign]", quote(do: [t("assign")]), true},
        {"[reopen]", quote(do: [t("reopen")]), true},
        {"[resubmit, unblocked]", quote(do: [t("resubmit"), t("unblocked")]), true},
        {"[assign, auto retry]", quote(do: [t("assign"), auto_retry()]), true},
        {"[unblocked]", quote(do: [t("unblocked")]), false},
        {"[answer(true)]", quote(do: [answer(true)]), true},
        {"[answer(true), auto retry]", quote(do: [answer(true), auto_retry()]), true},
        {"[]", quote(do: []), false},
        {"[auto retry]", quote(do: [auto_retry()]), false},
        {"[assign, manual retry]", quote(do: [t("assign"), manual_retry()]), false},
        {"[assign, manual]", quote(do: [t("assign"), t("manual")]), false},
        {"[mention]", quote(do: [t("mention")]), false},
        {"[requested]", quote(do: [t("requested")]), false},
        {"[answer(false)]", quote(do: [answer(false)]), false},
        {"[answer without the key]", quote(do: [t("answer")]), false}
      ] do
    @expected expected
    test "#{name} → #{expected}" do
      bound = Triggers.run_bound(%{triggers: unquote(triggers), agent_id: 7, squad_id: nil})
      assert bound == if(@expected, do: {:actor, 7})
    end
  end

  describe "bound_assignee/2 (add-squads decision 10)" do
    @plain %{agent_id: 7, squad_id: nil}
    @leader %{agent_id: 7, squad_id: 3}

    test "assignment triggers and delegate_done: the squad of a leader run, else the agent" do
      for kind <- ~w(assign reopen resubmit delegate_done) do
        assert Triggers.bound_assignee(t(kind), @plain) == {:actor, 7}
        assert Triggers.bound_assignee(t(kind), @leader) == {:squad, 3}
      end
    end

    test "delegated: the squad of the entry" do
      assert Triggers.bound_assignee(t("delegated", %{"squad_id" => 4}), @plain) == {:squad, 4}
    end

    test "answers: the recorded assignee; older entries the run's agent" do
      assert Triggers.bound_assignee(t("answer", %{"bound_assignee_id" => 9}), @plain) ==
               {:actor, 9}

      assert Triggers.bound_assignee(
               t("answer", %{"assignee_bound" => true, "bound_assignee_id" => 9}),
               @leader
             ) == {:actor, 9}

      assert Triggers.bound_assignee(answer(true), @leader) == {:actor, 7}
      assert Triggers.bound_assignee(answer(false), @leader) == nil
    end

    test "nothing else is bound" do
      for kind <- ~w(manual mention requested steer unblocked retry delegated) do
        assert Triggers.bound_assignee(t(kind), @leader) == nil
      end
    end

    test "run_bound/1 needs one target for every trigger" do
      run = %{triggers: [t("assign"), t("delegate_done")], agent_id: 7, squad_id: 3}
      assert Triggers.run_bound(run) == {:squad, 3}

      run = %{run | triggers: [t("assign"), t("answer", %{"bound_assignee_id" => 7})]}
      assert Triggers.run_bound(run) == nil
    end
  end

  describe "dependency_gated?/1" do
    for {name, triggers, expected} <- [
          {"[assign]", quote(do: [t("assign")]), true},
          {"[reopen, retry(auto)]", quote(do: [t("reopen"), auto_retry()]), true},
          {"[assign, unblocked]", quote(do: [t("assign"), t("unblocked")]), true},
          {"[resubmit, reopen]", quote(do: [t("resubmit"), t("reopen")]), true},
          {"[]", quote(do: []), false},
          {"[unblocked]", quote(do: [t("unblocked")]), false},
          {"[retry(auto)]", quote(do: [auto_retry()]), false},
          {"[assign, manual]", quote(do: [t("assign"), t("manual")]), false},
          {"[assign, answer(assignee_bound)]", quote(do: [t("assign"), answer(true)]), false},
          {"[resubmit, retry(manual)]", quote(do: [t("resubmit"), manual_retry()]), false},
          {"[mention]", quote(do: [t("mention")]), false},
          {"[autopilot]", quote(do: [t("autopilot")]), false}
        ] do
      @expected expected
      test "#{name} → #{expected}" do
        assert Triggers.dependency_gated?(unquote(triggers)) == @expected
      end
    end
  end
end
