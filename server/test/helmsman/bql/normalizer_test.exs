defmodule Helmsman.BQL.NormalizerTest do
  use ExUnit.Case, async: true
  alias Helmsman.BQL
  alias Helmsman.BQL.Fields

  test "every field/operator pair and alias" do
    for field <- BQL.fields(),
        op <- [:eq, :neq, :in, :not_in, :match, :nmatch, :gt, :gte, :lt, :lte, :empty, :not_empty] do
      v = sample(field.values)

      suffix =
        cond do
          op in [:empty, :not_empty] -> ""
          op in [:in, :not_in] -> " (#{v})"
          true -> " #{v}"
        end

      q = "#{field.name} #{Fields.symbol(op)}#{suffix}"

      if op in field.operators do
        assert {:ok, _} = BQL.parse(q), q
      else
        assert {:error, {:invalid_bql, %{message: message}}} = BQL.parse(q)
        assert message == "operator #{Fields.symbol(op)} not supported for #{field.name}"
      end
    end

    for f <- BQL.fields(), alias_name <- f.aliases do
      assert BQL.parse("#{alias_name} #{Fields.symbol(hd(f.operators))} #{sample(f.values)}") ==
               BQL.parse("#{f.name} #{Fields.symbol(hd(f.operators))} #{sample(f.values)}")
    end
  end

  test "currentUser stays symbolic and is limited to equality on identities" do
    for f <- [:assignee, :created_by, :owner], op <- ["=", "!=", "IN", "NOT IN"] do
      v = if op in ["IN", "NOT IN"], do: "(CURRENTuser())", else: "CURRENTuser()"
      assert {:ok, %{where: {:cond, ^f, _, value}}} = BQL.parse("#{f} #{op} #{v}")
      assert value in [:current_user, [:current_user]]
    end

    for f <- BQL.fields(), f.name not in [:assignee, :created_by, :owner] do
      assert {:error, {:invalid_bql, %{message: message}}} =
               BQL.parse("#{f.name} #{Fields.symbol(hd(f.operators))} currentUser()")

      assert message == "currentUser() is not supported for #{f.name}"
    end

    assert {:error, {:invalid_bql, %{message: "currentUser() is not supported for assignee"}}} =
             BQL.parse("assignee ~ currentUser()")
  end

  test "UTC dates and one injected clock" do
    now = ~U[2026-10-14 13:00:00Z]

    assert {:ok, %{where: {:and, [{:cond, :created, :gte, t}, {:cond, :updated, :gte, t}]}}} =
             BQL.parse("created >= -7d AND updated >= -7d", now: now)

    for {v, t} <- [
          {"2026-09-01", ~U[2026-09-01 00:00:00Z]},
          {"2026-09-01t12:30", ~U[2026-09-01 12:30:00Z]},
          {"2026-09-01T12:30:45", ~U[2026-09-01 12:30:45Z]},
          {"now", now},
          {"-1m", DateTime.add(now, -60)},
          {"-1h", DateTime.add(now, -3600)},
          {"-1w", DateTime.add(now, -604_800)}
        ] do
      assert {:ok, %{where: {:cond, :created, :gte, ^t}}} = BQL.parse("created >= #{v}", now: now)
    end

    for v <- [
          "yesterday",
          "2026-02-30",
          "-0d",
          "-100001d",
          "2026-01-01T25:00",
          "2026-01-01T00:00:00Z"
        ] do
      assert {:error, {:invalid_bql, %{message: message, position: 12}}} =
               BQL.parse("created >= #{v}")

      assert message == "invalid date '#{v}'"
    end
  end

  defp sample(values) when is_list(values), do: hd(values)
  defp sample(:task_id), do: "BQ-1"
  defp sample(:boolean), do: "true"
  defp sample(:integer), do: "1"
  defp sample(:date), do: "2026-01-01"
  defp sample(_), do: "hello"
end
