defmodule Helmsman.BQL.Validator do
  @moduledoc "Bounded structural and typed-value validation for canonical ASTs."
  alias Helmsman.BQL.{Fields, Normalizer, Printer}

  def validate(%{where: where, order: order} = ast) when map_size(ast) == 2 do
    {_conditions, size} = expression(where, 0, 0, 0, 0, true)
    validate_order(order, size)
    {:ok, %{ast | where: canonicalize(where)}}
  catch
    {:invalid_ast, message} -> error(message)
  end

  def validate(_), do: error("invalid BQL AST")

  defp expression(node, parent, depth, count, size, root?) do
    depth = depth + if(Printer.parentheses?(node, parent), do: 1, else: 0)
    if depth > 32, do: fail("too much nesting (at most 32)")
    visit(node, depth, count, size, root?)
  end

  defp visit(true, _depth, count, size, true), do: {count, size}

  defp visit({:not, child}, depth, count, size, _root?),
    do: expression(child, 3, depth + 1, count, size, false)

  defp visit({op, [_, _ | _] = nodes} = node, depth, count, size, _root?)
       when op in [:and, :or] do
    bounded_length(nodes, 64, "too many conditions (at most 64)")

    Enum.reduce(nodes, {count, size}, fn child, {count, size} ->
      expression(child, Printer.precedence(node), depth, count, size, false)
    end)
  end

  defp visit({:cond, name, op, value}, _depth, count, size, _root?) when is_atom(name) do
    if count >= 64, do: fail("too many conditions (at most 64)")
    field = canonical_field(name)
    unless op in field.operators, do: fail("invalid operator for #{name}")

    size =
      cond do
        op in [:empty, :not_empty] ->
          unless value == true, do: fail("invalid empty-condition value")
          size

        op in [:in, :not_in] ->
          unless is_list(value) and value != [], do: fail("invalid IN values")
          bounded_length(value, 100, "too many IN values (at most 100)")
          Enum.reduce(value, size, &validate_value(field, op, &1, &2))

        true ->
          validate_value(field, op, value, size)
      end

    {count + 1, size}
  end

  defp visit(_, _depth, _count, _size, _root?), do: fail("invalid BQL AST node")

  defp canonical_field(name) do
    field = Fields.fetch(Atom.to_string(name))
    unless field && field.name == name, do: fail("unknown field '#{name}'")
    field
  end

  defp validate_order(order, size) when is_list(order) do
    bounded_length(order, 5, "too many ORDER BY fields (at most 5)")

    Enum.reduce(order, size, fn
      {name, direction}, size when is_atom(name) and direction in [:asc, :desc] ->
        field = canonical_field(name)
        unless field.sortable, do: fail("field '#{name}' cannot be used in ORDER BY")
        size

      _, _ ->
        fail("invalid ORDER BY field")
    end)
  end

  defp validate_order(_, _size), do: fail("invalid ORDER BY fields")

  defp validate_value(field, op, :current_user, size) do
    if field.name in [:assignee, :created_by, :owner] and op in [:eq, :neq, :in, :not_in],
      do: size,
      else: fail("currentUser() is not supported for #{field.name}")
  end

  defp validate_value(%{values: :boolean}, _op, value, size) when is_boolean(value), do: size

  defp validate_value(%{values: :integer}, _op, value, size)
       when is_integer(value) and value >= 0,
       do: size

  defp validate_value(%{values: :date}, _op, value, size) do
    unless canonical_date?(value), do: fail("invalid date in BQL AST")
    size
  end

  defp validate_value(field, op, value, size) when is_binary(value) do
    unless String.valid?(value), do: fail("invalid UTF-8")
    size = add_size(size, value)
    scalar_op = if op in [:in, :not_in], do: :eq, else: op
    raw = %{where: {:cond, Atom.to_string(field.name), scalar_op, {value, 1}, 1, 1}, order: []}

    case Normalizer.normalize(raw) do
      {:ok, %{where: {:cond, _, _, ^value}}} -> size
      _ -> fail("invalid canonical value for #{field.name}")
    end
  end

  defp validate_value(field, _op, _value, _size),
    do: fail("invalid canonical value for #{field.name}")

  defp canonical_date?(%DateTime{
         calendar: Calendar.ISO,
         utc_offset: 0,
         std_offset: 0,
         time_zone: "Etc/UTC",
         zone_abbr: "UTC",
         microsecond: {0, 0},
         year: year,
         month: month,
         day: day,
         hour: hour,
         minute: minute,
         second: second
       })
       when is_integer(year) and is_integer(month) and is_integer(day) and is_integer(hour) and
              is_integer(minute) and is_integer(second) do
    match?({:ok, _}, Date.new(year, month, day)) and
      match?({:ok, _}, Time.new(hour, minute, second))
  end

  defp canonical_date?(_), do: false

  # ASTs have no source spelling. Bound string values independently; the lexer
  # enforces the 2000-codepoint source limit.
  defp add_size(size, value) do
    size = size + length(String.codepoints(value))
    if size > 4000, do: fail("query is too long")
    size
  end

  defp bounded_length([], _remaining, _message), do: :ok
  defp bounded_length([_ | _], 0, message), do: fail(message)

  defp bounded_length([_ | tail], remaining, message),
    do: bounded_length(tail, remaining - 1, message)

  defp bounded_length(_, _remaining, _message), do: fail("invalid BQL AST list")

  defp canonicalize({op, nodes}) when op in [:and, :or] do
    {op,
     Enum.flat_map(nodes, fn child ->
       case canonicalize(child) do
         {^op, children} -> children
         normalized -> [normalized]
       end
     end)}
  end

  defp canonicalize({:not, child}), do: {:not, canonicalize(child)}
  defp canonicalize(node), do: node

  defp fail(message), do: throw({:invalid_ast, message})
  defp error(message), do: {:error, {:invalid_bql, %{message: message, position: 1}}}
end
