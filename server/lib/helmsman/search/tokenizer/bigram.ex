defmodule Helmsman.Search.Tokenizer.Bigram do
  @moduledoc """
  The default tokenizer (`add-fulltext-search` decision 3, designs/10 §1.1):

    * a run of CJK characters (Han, Hiragana, Katakana, Hangul) gives its
      adjacent bigrams, one position each; a single character gives
      itself;
    * a word of other letters, digits and combining marks, which may
      contain `-`, `_` and `/` between two word characters, gives itself
      and, when it has connectors, each different fragment at its own
      position;
    * every term is NFKC-normalized and downcased; offsets point to the
      original text;
    * the stop words (`the`, `a`, and `的`, `了` on their own) and terms
      longer than 64 code points once normalized are not output, but stop
      words keep their position.

  A CJK "character" is a grapheme, so a combining voiced sound mark stays
  with its kana. The script classes use the script extensions of the
  regular expression library, which also cover the prolonged sound mark
  `ー`; punctuation such as `、` is still a separator (letters, digits and
  marks only).
  """

  @behaviour Helmsman.Search.Tokenizer

  @cjk "\\p{Han}\\p{Hiragana}\\p{Katakana}\\p{Hangul}"
  @cjk_char "(?:(?=[\\p{L}\\p{N}\\p{M}])[#{@cjk}])"
  @word_char "(?:(?![#{@cjk}])[\\p{L}\\p{N}\\p{M}])"
  @runs Regex.compile!("(#{@cjk_char}+)|(#{@word_char}+(?:[-_/]#{@word_char}+)*)", "u")
  @connectors ["-", "_", "/"]
  @connector ~r{[-_/]}
  @latin_stop_words ["the", "a"]
  @cjk_stop_words ["的", "了"]
  @max_term_length 64
  @max_groups 16

  @impl Helmsman.Search.Tokenizer
  def tokens(text) when is_binary(text) do
    text
    |> runs()
    |> Enum.flat_map_reduce(0, fn run, pos -> run_tokens(run, pos) end)
    |> elem(0)
  end

  @impl Helmsman.Search.Tokenizer
  def query(text) when is_binary(text) do
    text
    |> runs()
    |> Enum.flat_map(&run_groups/1)
    |> prefix_last()
    |> Enum.uniq()
    |> Enum.take(@max_groups)
  end

  ## Runs

  # `{:cjk, [{grapheme, start, len}]}` or `{:word, word, start}`, in order.
  defp runs(text) do
    @runs
    |> Regex.scan(text, return: :index, capture: :all)
    |> Enum.map(fn
      [{start, len}, {start, len} | _] -> {:cjk, graphemes(binary_part(text, start, len), start)}
      [{start, len} | _] -> {:word, binary_part(text, start, len), start}
    end)
  end

  defp graphemes(run, start) do
    run
    |> String.graphemes()
    |> Enum.map_reduce(start, fn g, offset ->
      {{g, offset, byte_size(g)}, offset + byte_size(g)}
    end)
    |> elem(0)
  end

  ## Tokens

  defp run_tokens({:word, word, start}, pos) do
    whole = normalize(word)

    tokens =
      if whole in @latin_stop_words,
        do: [],
        else:
          keep([token(whole, pos, start, byte_size(word)) | fragments(word, whole, pos, start)])

    {tokens, pos + 1}
  end

  defp run_tokens({:cjk, [{g, start, len}]}, pos) do
    term = normalize(g)
    tokens = if term in @cjk_stop_words, do: [], else: keep([token(term, pos, start, len)])
    {tokens, pos + 1}
  end

  defp run_tokens({:cjk, chars}, pos) do
    tokens =
      chars
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.with_index(pos)
      |> Enum.map(fn {[{a, start, len_a}, {b, _, len_b}], p} ->
        token(normalize(a <> b), p, start, len_a + len_b)
      end)

    {keep(tokens), pos + length(chars) - 1}
  end

  # The fragments of a word with connectors, each at the word's position,
  # with their own offsets; those equal to the whole word are left out.
  defp fragments(word, whole, pos, start) do
    word
    |> split_connectors(start)
    |> Enum.flat_map(fn {fragment, offset} ->
      case normalize(fragment) do
        ^whole -> []
        term when term in @latin_stop_words -> []
        term -> [token(term, pos, offset, byte_size(fragment))]
      end
    end)
    |> Enum.uniq_by(& &1.term)
  end

  defp split_connectors(word, start) do
    @connector
    |> Regex.split(word, include_captures: true)
    |> Enum.map_reduce(start, fn part, offset -> {{part, offset}, offset + byte_size(part)} end)
    |> elem(0)
    |> Enum.reject(fn {part, _offset} -> part in @connectors or part == "" end)
  end

  defp token(term, pos, start, len), do: %{term: term, pos: pos, start: start, len: len}

  defp keep(tokens), do: Enum.filter(tokens, &short?(&1.term))

  # At most 64 code points once normalized, so at most 256 bytes: well under
  # PostgreSQL's lexeme limit (2047 bytes). Graphemes are not the measure:
  # one letter may carry any number of combining marks.
  defp short?(term), do: codepoints(term, 0) <= @max_term_length

  defp codepoints(_rest, n) when n > @max_term_length, do: n
  defp codepoints(<<_::utf8, rest::binary>>, n), do: codepoints(rest, n + 1)
  defp codepoints(<<_byte, rest::binary>>, n), do: codepoints(rest, n + 1)
  defp codepoints(<<>>, n), do: n

  defp normalize(text), do: text |> :unicode.characters_to_nfkc_binary() |> String.downcase()

  ## Query groups

  defp run_groups({:word, word, start}) do
    whole = normalize(word)

    cond do
      whole in @latin_stop_words ->
        []

      short?(whole) ->
        [{:word, whole}]

      # Never indexed whole: its indexed fragments instead.
      true ->
        word |> fragments(whole, 0, start) |> keep() |> Enum.map(&{:term, &1.term})
    end
  end

  defp run_groups({:cjk, [{g, _start, _len}]}) do
    term = normalize(g)
    if term in @cjk_stop_words or not short?(term), do: [], else: [{:prefix, term}]
  end

  defp run_groups({:cjk, _chars} = run) do
    {tokens, _pos} = run_tokens(run, 0)

    case Enum.map(tokens, & &1.term) do
      [] -> []
      [bigram] -> [{:term, bigram}]
      bigrams -> [{:phrase, bigrams}]
    end
  end

  # The last word is still being typed: a prefix. Words elsewhere are terms.
  defp prefix_last(groups) do
    {last, rest} = List.pop_at(groups, -1)

    Enum.map(rest, &word_to_term/1) ++
      case last do
        nil -> []
        {:word, word} -> [{:prefix, word}]
        group -> [group]
      end
  end

  defp word_to_term({:word, word}), do: {:term, word}
  defp word_to_term(group), do: group
end
