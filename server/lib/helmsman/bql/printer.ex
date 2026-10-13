defmodule Helmsman.BQL.Printer do
  @moduledoc "Canonical BQL rendering with quoted and escaped values."
  import Kernel, except: [node: 1]
  alias Helmsman.BQL.Fields

  def print(%{where: expr, order: order}) do
    [node(expr, 0), sort(order)] |> Enum.reject(&(&1 == "")) |> Enum.join(" ")
  end

  def precedence({:or, _}), do: 1
  def precedence({:and, _}), do: 2
  def precedence({:not, _}), do: 3
  def precedence(_), do: 4

  # NOT itself already contributes one parser nesting level.
  def parentheses?(expr, parent), do: precedence(expr) < parent

  defp node(expr, parent) do
    text = node(expr)
    if parentheses?(expr, parent), do: "(" <> text <> ")", else: text
  end

  defp node(true), do: ""

  defp node({op, nodes} = expr) when op in [:and, :or],
    do: Enum.map_join(nodes, " #{String.upcase(to_string(op))} ", &node(&1, precedence(expr)))

  defp node({:not, child}), do: "NOT " <> node(child, 3)

  defp node({:cond, field, op, _value}) when op in [:empty, :not_empty],
    do: "#{field} #{Fields.symbol(op)}"

  defp node({:cond, field, op, values}) when op in [:in, :not_in],
    do: "#{field} #{Fields.symbol(op)} (#{Enum.map_join(values, ", ", &value/1)})"

  defp node({:cond, field, op, v}), do: "#{field} #{Fields.symbol(op)} #{value(v)}"
  defp value(:current_user), do: "currentUser()"

  defp value(%DateTime{} = date) do
    value(Calendar.strftime(date, "%Y-%m-%dT%H:%M:%S"))
  end

  defp value(v) when is_boolean(v) or is_integer(v), do: to_string(v)

  defp value(v) do
    if v != "" and
         String.downcase(v) not in ~w(and or not in is empty null order by asc desc currentuser) and
         not Enum.any?(
           String.codepoints(v),
           &(String.trim(&1) == "" or &1 in ~w[( ) , " = ! ~ < >])
         ) do
      v
    else
      "\"" <> (v |> String.replace("\\", "\\\\") |> String.replace("\"", "\\\"")) <> "\""
    end
  end

  defp sort([]), do: ""

  defp sort(fields),
    do:
      "ORDER BY " <>
        Enum.map_join(fields, ", ", fn {f, d} -> "#{f} #{String.upcase(to_string(d))}" end)
end
