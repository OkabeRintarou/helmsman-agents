defmodule Helmsman.BQL.Normalizer do
  @moduledoc "Canonical fields and typed values; current identity stays symbolic."
  alias Helmsman.BQL.Fields
  alias Helmsman.Tasks.{Ident, StateMachine, Task}

  def normalize(raw, opts \\ []) do
    now = opts |> Keyword.get_lazy(:now, &DateTime.utc_now/0) |> DateTime.truncate(:second)

    try do
      {:ok, %{where: node(raw.where, now), order: Enum.map(raw.order, &sort_field/1)}}
    catch
      {:bql_error, message, pos} -> {:error, {:invalid_bql, %{message: message, position: pos}}}
    end
  end

  defp node(true, _now), do: true

  defp node({op, nodes}, now) when op in [:and, :or] do
    {op,
     Enum.flat_map(nodes, fn child ->
       case node(child, now) do
         {^op, children} -> children
         normalized -> [normalized]
       end
     end)}
  end

  defp node({:not, child}, now), do: {:not, node(child, now)}

  defp node({:cond, name, op, raw, pos, opos}, now) do
    field = Fields.fetch(name) || fail("unknown field '#{name}'", pos)

    unless op in field.operators,
      do: fail("operator #{Fields.symbol(op)} not supported for #{field.name}", opos)

    value =
      cond do
        op in [:empty, :not_empty] -> true
        op in [:in, :not_in] -> Enum.map(raw, &value(field, op, &1, now))
        true -> value(field, op, raw, now)
      end

    {:cond, field.name, op, value}
  end

  defp sort_field({name, direction, pos}) do
    field = Fields.fetch(name) || fail("unknown field '#{name}' in ORDER BY", pos)
    unless field.sortable, do: fail("field '#{name}' cannot be used in ORDER BY", pos)
    {field.name, direction}
  end

  defp value(field, op, {:current_user, pos}, _now) do
    if field.name in [:assignee, :created_by, :owner] and op in [:eq, :neq, :in, :not_in],
      do: :current_user,
      else: fail("currentUser() is not supported for #{field.name}", pos)
  end

  defp value(field, op, {raw, pos}, now) do
    typed_value(field.values, field.name, op, raw, pos, now)
  end

  defp typed_value(type, _field, _op, raw, _pos, _now) when type in [:name, :identity],
    do: String.downcase(raw)

  defp typed_value(:text, _field, _op, raw, _pos, _now), do: raw

  defp typed_value(:task_id, _field, op, raw, _pos, _now) when op in [:match, :nmatch],
    do: String.downcase(raw)

  defp typed_value(:task_id, _field, _op, raw, pos, _now), do: task_id(raw, pos)
  defp typed_value(:status, _field, _op, raw, pos, _now), do: status(raw, pos)
  defp typed_value(:boolean, _field, _op, raw, pos, _now), do: boolean(raw, pos)
  defp typed_value(:integer, _field, _op, raw, pos, _now), do: integer(raw, pos)
  defp typed_value(:date, _field, _op, raw, pos, now), do: date(raw, pos, now)

  defp typed_value(values, field, _op, raw, pos, _now) when is_list(values),
    do: enum(field, raw, values, pos)

  defp task_id(raw, pos) do
    case Ident.parse(raw) do
      {:ok, ident, _, _} -> ident
      _ -> fail("invalid task id '#{raw}'", pos)
    end
  end

  defp status(raw, pos) do
    case StateMachine.normalize(raw) do
      {:ok, value} -> Atom.to_string(value)
      _ -> fail("invalid status '#{raw}'", pos)
    end
  end

  defp boolean(raw, pos) do
    case String.downcase(raw) do
      v when v in ["true", "yes"] -> true
      v when v in ["false", "no"] -> false
      _ -> fail("invalid boolean '#{raw}'", pos)
    end
  end

  defp integer(raw, pos) do
    case Integer.parse(raw) do
      {n, ""} when n >= 0 -> n
      _ -> fail("invalid integer '#{raw}'", pos)
    end
  end

  defp enum(field, raw, values, pos) do
    lower = String.downcase(raw)

    label =
      case field do
        :run -> "run status"
        :pr -> "pr state"
        :ci -> "ci state"
        :merge -> "merge status"
        _ -> to_string(field)
      end

    if lower in values, do: lower, else: fail("invalid #{label} '#{raw}'", pos)
  end

  defp date(raw, pos, now) do
    lower = String.downcase(raw)

    case Regex.run(~r/^-(\d+)([mhdw])$/, lower) do
      [_, n, unit] ->
        n = String.to_integer(n)
        if n < 1 or n > 100_000, do: fail("invalid date '#{raw}'", pos)

        DateTime.add(
          now,
          -n * %{"m" => 60, "h" => 3600, "d" => 86_400, "w" => 604_800}[unit],
          :second
        )

      _ ->
        absolute_date(lower, raw, pos, now)
    end
  end

  defp absolute_date("now", _raw, _pos, now), do: now

  defp absolute_date(lower, raw, pos, _now) do
    iso =
      case lower do
        <<d::binary-size(10)>> -> d <> "T00:00:00Z"
        <<d::binary-size(10), "t", h::binary-size(5)>> -> d <> "T" <> h <> ":00Z"
        <<d::binary-size(10), "t", h::binary-size(8)>> -> d <> "T" <> h <> "Z"
        _ -> ""
      end

    case DateTime.from_iso8601(iso) do
      {:ok, date, 0} -> date
      _ -> fail("invalid date '#{raw}'", pos)
    end
  end

  def values(:status), do: Enum.map(Task.statuses(), &to_string/1)
  def values(other), do: other
  defp fail(message, pos), do: throw({:bql_error, message, pos})
end
