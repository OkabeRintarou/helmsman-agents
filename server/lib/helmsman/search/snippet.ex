defmodule Helmsman.Search.Snippet do
  @moduledoc """
  Search snippets (`add-fulltext-search` decision 7, designs/10 §1.3),
  made in the application with the tokenizer, never from HTML the
  database produced.

  `build/2` returns segments (`%{text, hit}`); the domain never produces
  HTML. `to_html/1` escapes every segment before marking the hits;
  `to_text/1` marks them with `**` (MCP).
  """

  alias Helmsman.Search.Tokenizer

  @type segment :: %{text: String.t(), hit: boolean()}
  @type segments :: [segment(), ...]

  @context 40
  @ellipsis "…"

  @doc """
  The snippet of `text` around its first hit for `groups`: 40 graphemes
  on each side, every hit in the window marked (overlapping bigrams
  merged), runs of whitespace collapsed to one space and `…` where the
  text was cut. `nil` without a hit.
  """
  @spec build(String.t() | nil, [Tokenizer.group()]) :: segments() | nil
  def build(nil, _groups), do: nil
  def build(_text, []), do: nil

  def build(text, groups) when is_binary(text) and is_list(groups) do
    hits =
      for %{term: term, start: start, len: len} <- Tokenizer.tokens(text),
          hit?(term, groups),
          do: {start, start + len}

    case hits do
      [] -> nil
      hits -> snippet(text, hits)
    end
  end

  @doc "Whether a term matches one of `groups`."
  @spec hit?(String.t(), [Tokenizer.group()]) :: boolean()
  def hit?(term, groups) do
    Enum.any?(groups, fn
      {:term, t} -> term == t
      {:prefix, p} -> String.starts_with?(term, p)
      {:phrase, terms} -> term in terms
    end)
  end

  @doc "HTML: every segment escaped, the hits in `<mark>`."
  @spec to_html([segment()]) :: Phoenix.HTML.safe()
  def to_html(segments) when is_list(segments) do
    {:safe,
     Enum.map(segments, fn %{text: text, hit: hit} ->
       escaped = text |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
       if hit, do: ["<mark>", escaped, "</mark>"], else: escaped
     end)}
  end

  @doc "Plain text: the hits in `**`."
  @spec to_text([segment()]) :: String.t()
  def to_text(segments) when is_list(segments) do
    Enum.map_join(segments, fn
      %{text: text, hit: true} -> "**" <> text <> "**"
      %{text: text} -> text
    end)
  end

  ## Window

  defp snippet(text, hits) do
    {first_start, first_end} = Enum.min(hits)
    size = byte_size(text)

    before = text |> binary_part(0, first_start) |> String.graphemes() |> Enum.take(-@context)
    window_start = first_start - IO.iodata_length(before)

    after_ =
      text
      |> binary_part(first_end, size - first_end)
      |> String.graphemes()
      |> Enum.take(@context)

    window_end = first_end + IO.iodata_length(after_)

    intervals =
      hits
      |> Enum.filter(fn {s, e} -> s < window_end and e > window_start end)
      |> Enum.map(fn {s, e} -> {max(s, window_start), min(e, window_end)} end)
      |> merge()

    text
    |> segments(intervals, window_start, window_end)
    |> collapse(window_start > 0, window_end < size)
  end

  defp merge(intervals) do
    intervals
    |> Enum.sort()
    |> Enum.reduce([], fn
      {s, e}, [{ps, pe} | rest] when s <= pe -> [{ps, max(pe, e)} | rest]
      interval, acc -> [interval | acc]
    end)
    |> Enum.reverse()
  end

  defp segments(text, intervals, window_start, window_end) do
    {segments, cursor} =
      Enum.flat_map_reduce(intervals, window_start, fn {s, e}, cursor ->
        {[
           %{text: binary_part(text, cursor, s - cursor), hit: false},
           %{text: binary_part(text, s, e - s), hit: true}
         ], e}
      end)

    segments ++ [%{text: binary_part(text, cursor, window_end - cursor), hit: false}]
  end

  defp collapse(segments, cut_start?, cut_end?) do
    segments =
      Enum.map(segments, fn
        %{hit: false, text: text} = segment -> %{segment | text: squeeze(text)}
        segment -> segment
      end)

    segments
    |> update_edge(:first, fn text ->
      text = String.trim_leading(text)
      if cut_start?, do: @ellipsis <> text, else: text
    end)
    |> update_edge(:last, fn text ->
      text = String.trim_trailing(text)
      if cut_end?, do: text <> @ellipsis, else: text
    end)
    |> Enum.reject(&(&1.text == ""))
    |> Enum.chunk_by(& &1.hit)
    |> Enum.map(fn [%{hit: hit} | _] = chunk ->
      %{text: Enum.map_join(chunk, & &1.text), hit: hit}
    end)
  end

  # The first and the last segments are never hits: `segments/4` starts and
  # ends with the text around the hits, possibly empty.
  defp update_edge(segments, :first, fun), do: List.update_at(segments, 0, &edge(&1, fun))
  defp update_edge(segments, :last, fun), do: List.update_at(segments, -1, &edge(&1, fun))

  defp edge(%{hit: false, text: text} = segment, fun), do: %{segment | text: fun.(text)}

  defp squeeze(text), do: String.replace(text, ~r/\s+/u, " ")
end
