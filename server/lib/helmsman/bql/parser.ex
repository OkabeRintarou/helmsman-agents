defmodule Helmsman.BQL.Parser do
  @moduledoc "Bounded recursive descent parser; raw nodes retain source positions."
  alias Helmsman.BQL.Lexer

  def parse(input) do
    with {:ok, tokens} <- Lexer.tokenize(input) do
      try do
        {expr, tokens, count} =
          if elem(hd(tokens), 0) in [:eof, "order"],
            do: {true, tokens, 0},
            else: expression(tokens, 0, 0)

        {order, tokens} = order(tokens)

        case tokens do
          [{:eof, _, _}] -> {:ok, %{where: expr, order: order, conditions: count}}
          [token | _] -> fail("unexpected token '#{elem(token, 1)}'", token)
        end
      catch
        {:bql_error, message, pos} -> {:error, {:invalid_bql, %{message: message, position: pos}}}
      end
    end
  end

  defp expression(tokens, depth, count), do: chain(tokens, depth, count, "or", :or, &term/3)
  defp term(tokens, depth, count), do: chain(tokens, depth, count, "and", :and, &factor/3)

  defp chain(tokens, depth, count, keyword, op, next) do
    {node, rest, count} = next.(tokens, depth, count)
    chain_tail(rest, depth, count, keyword, op, next, [node])
  end

  defp chain_tail([{keyword, _, _} | tokens], depth, count, keyword, op, next, nodes) do
    {node, rest, count} = next.(tokens, depth, count)
    chain_tail(rest, depth, count, keyword, op, next, [node | nodes])
  end

  defp chain_tail(tokens, _depth, count, _keyword, op, _next, nodes),
    do: {if(length(nodes) == 1, do: hd(nodes), else: {op, Enum.reverse(nodes)}), tokens, count}

  defp factor([token | _], depth, _count) when depth > 32,
    do: fail("too much nesting (at most 32)", token)

  defp factor([{"not", _, _} | rest], depth, count) do
    {node, tokens, count} = factor(rest, depth + 1, count)
    {{:not, node}, tokens, count}
  end

  defp factor([{"(", _, _} | rest], depth, count) do
    {node, tokens, count} = expression(rest, depth + 1, count)
    {node, expect(tokens, ")", "expected ')'"), count}
  end

  defp factor([token | _], _depth, count) when count >= 64,
    do: fail("too many conditions (at most 64)", token)

  defp factor([{:word, name, pos} | rest], _depth, count) do
    {op, opos, values, rest} = condition(rest)
    {{:cond, String.downcase(name), op, values, pos, opos}, rest, count + 1}
  end

  defp factor([token | _], _depth, _count), do: fail("expected a field", token)

  defp condition([{:op, op, pos} | rest]) do
    {value, rest} = value(rest)
    {op, pos, value, rest}
  end

  defp condition([{"in", _, pos} | rest]), do: in_list(rest, :in, pos)
  defp condition([{"not", _, pos}, {"in", _, _} | rest]), do: in_list(rest, :not_in, pos)

  defp condition([{"is", _, pos} | rest]) do
    {op, rest} =
      case rest do
        [{"not", _, _} | tail] -> {:not_empty, tail}
        _ -> {:empty, rest}
      end

    case rest do
      [{kind, _, vpos} | tail] when kind in ["empty", "null"] -> {op, pos, {true, vpos}, tail}
      [token | _] -> fail("expected EMPTY or NULL", token)
    end
  end

  defp condition([token | _]), do: fail("expected an operator", token)

  defp in_list(tokens, op, pos) do
    tokens = expect(tokens, "(", "expected '('")
    {v, rest} = value(tokens)
    {values, rest} = list_tail(rest, [v])
    {op, pos, Enum.reverse(values), rest}
  end

  defp list_tail([{",", _, _} | tokens], values) do
    if length(values) >= 100, do: fail("too many IN values (at most 100)", hd(tokens))
    {v, rest} = value(tokens)
    list_tail(rest, [v | values])
  end

  defp list_tail(tokens, values), do: {values, expect(tokens, ")", "expected ')'")}

  defp value([{kind, value, pos} | rest]) when kind in [:word, :string, :current_user],
    do: {{value, pos}, rest}

  defp value([token | _]), do: fail("expected a value", token)
  defp order([{"order", _, _} | rest]), do: order_fields(expect(rest, "by", "expected BY"), [])
  defp order(tokens), do: {[], tokens}

  defp order_fields([{:word, name, pos} | rest], fields) do
    if length(fields) >= 5, do: fail("too many ORDER BY fields (at most 5)", {:word, name, pos})

    {direction, rest} =
      case rest do
        [{"desc", _, _} | tail] -> {:desc, tail}
        [{"asc", _, _} | tail] -> {:asc, tail}
        _ -> {:asc, rest}
      end

    fields = [{String.downcase(name), direction, pos} | fields]

    case rest do
      [{",", _, _} | tail] -> order_fields(tail, fields)
      _ -> {Enum.reverse(fields), rest}
    end
  end

  defp order_fields([token | _], _fields), do: fail("expected a field in ORDER BY", token)
  defp expect([{kind, _, _} | rest], kind, _message), do: rest
  defp expect([token | _], _kind, message), do: fail(message, token)
  defp fail(message, {_, _, pos}), do: throw({:bql_error, message, pos})
end
