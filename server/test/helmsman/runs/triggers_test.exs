defmodule Helmsman.Runs.TriggersTest do
  # add-continuation-triggers 1.6: `assignee_bound?/1` (decision 8).
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
end
