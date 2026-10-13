defmodule Helmsman.BQL.RoundtripPropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties
  alias Helmsman.BQL

  property "arbitrary unicode and invalid bytes never crash the parser" do
    check all input <- one_of([string(:utf8, max_length: 2100), binary(max_length: 2100)]),
              max_runs: 150 do
      assert match?({:ok, _}, BQL.parse(input)) or
               match?({:error, {:invalid_bql, _}}, BQL.parse(input))
    end
  end

  property "all fields/operators, nested expressions and escaped values roundtrip" do
    sortable = BQL.fields() |> Enum.filter(& &1.sortable) |> Enum.map(& &1.name)

    check all where <- expression(3),
              order <-
                list_of(tuple({member_of(sortable), member_of([:asc, :desc])}), max_length: 5),
              max_runs: 200 do
      ast = %{where: where, order: order}
      assert {:ok, normalized} = BQL.parse(BQL.to_string(ast))
      assert {:ok, ^normalized} = BQL.validate_ast(normalized)
      assert {:ok, ^normalized} = BQL.parse(BQL.to_string(normalized))
    end
  end

  defp expression(0), do: condition()

  defp expression(depth) do
    child = expression(depth - 1)

    one_of([
      condition(),
      map(child, &{:not, &1}),
      map(list_of(child, min_length: 2, max_length: 2), &{:and, &1}),
      map(list_of(child, min_length: 2, max_length: 2), &{:or, &1})
    ])
  end

  defp condition do
    bind(member_of(BQL.fields()), fn field ->
      bind(member_of(field.operators), fn op ->
        map(value(field.values), &make_condition(field.name, op, &1))
      end)
    end)
  end

  defp make_condition(field, op, value) do
    value =
      cond do
        op in [:empty, :not_empty] -> true
        op in [:in, :not_in] -> [value]
        true -> value
      end

    {:cond, field, op, value}
  end

  defp value(values) when is_list(values), do: member_of(values)
  defp value(:task_id), do: constant("BQ-12")
  defp value(:boolean), do: boolean()

  defp value(:integer),
    do:
      one_of([
        integer(0..10_000),
        member_of([2_147_483_647, 2_147_483_648, 9_223_372_036_854_775_808])
      ])

  defp value(:date), do: constant(~U[2026-01-01 13:00:00Z])

  defp value(type) when type in [:name, :identity],
    do: member_of(["hello", "中文", "a\"b\\c", "and"])

  defp value(_), do: member_of(["Hello", "中文", "a\"b\\c", "AND", "\n\r\t", "a\u2003b", ""])
end
