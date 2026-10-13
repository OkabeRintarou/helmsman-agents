defmodule Helmsman.Runs.TriggersTest do
  # add-continuation-triggers 1.6: `assignee_bound?/1` (decision 8);
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
      assert Triggers.assignee_bound?(unquote(triggers)) == @expected
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
