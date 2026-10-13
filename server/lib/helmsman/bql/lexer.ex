defmodule Helmsman.BQL.Lexer do
  @moduledoc "BQL tokens with one-based Unicode codepoint positions."
  @keywords ~w(and or not in is empty null order by asc desc)
  @operators %{
    "=" => :eq,
    "!=" => :neq,
    "~" => :match,
    "!~" => :nmatch,
    ">" => :gt,
    ">=" => :gte,
    "<" => :lt,
    "<=" => :lte
  }
  def tokenize(input) when is_binary(input) do
    cond do
      not String.valid?(input) -> error("invalid UTF-8", 1)
      length(String.codepoints(input)) > 2000 -> error("query is too long", 2001)
      true -> scan(String.codepoints(input), 1, [])
    end
  end

  def tokenize(_), do: error("query must be a string", 1)
  defp scan([], pos, acc), do: {:ok, Enum.reverse([{:eof, "", pos} | acc])}

  defp scan(["\"" | rest], pos, acc) do
    with {:ok, value, tail, next} <- quoted(rest, pos + 1, pos, []),
         do: scan(tail, next, [{:string, value, pos} | acc])
  end

  defp scan([c | rest] = chars, pos, acc) do
    cond do
      String.trim(c) == "" -> scan(rest, pos + 1, acc)
      c in ["(", ")", ","] -> scan(rest, pos + 1, [{c, c, pos} | acc])
      c in ["=", "!", "~", ">", "<"] -> operator(chars, pos, acc)
      true -> word(chars, pos, acc)
    end
  end

  defp operator([a, "=" | rest], pos, acc) when a in ["!", ">", "<"],
    do: scan(rest, pos + 2, [{:op, @operators[a <> "="], pos} | acc])

  defp operator(["!", "~" | rest], pos, acc), do: scan(rest, pos + 2, [{:op, :nmatch, pos} | acc])

  defp operator([c | rest], pos, acc) do
    case @operators[c] do
      nil -> error("unexpected token '#{c}'", pos)
      op -> scan(rest, pos + 1, [{:op, op, pos} | acc])
    end
  end

  defp word(chars, pos, acc) do
    {word, rest} =
      Enum.split_while(
        chars,
        &(String.trim(&1) != "" and &1 not in ["(", ")", ",", "\"", "=", "!", "~", ">", "<"])
      )

    value = Enum.join(word)
    lower = String.downcase(value)

    case {lower, rest} do
      {"currentuser", ["(", ")" | tail]} ->
        scan(tail, pos + length(word) + 2, [{:current_user, :current_user, pos} | acc])

      _ ->
        scan(rest, pos + length(word), [
          {if(lower in @keywords, do: lower, else: :word), value, pos} | acc
        ])
    end
  end

  defp quoted([], _pos, start, _acc), do: error("unterminated string", start)

  defp quoted(["\"" | rest], pos, _start, acc),
    do: {:ok, acc |> Enum.reverse() |> Enum.join(), rest, pos + 1}

  defp quoted(["\\", c | rest], pos, start, acc) when c in ["\\", "\""],
    do: quoted(rest, pos + 2, start, [c | acc])

  defp quoted([c | rest], pos, start, acc), do: quoted(rest, pos + 1, start, [c | acc])

  defp error(message, position),
    do: {:error, {:invalid_bql, %{message: message, position: position}}}
end
