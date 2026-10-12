defmodule HelmsmanDaemon.LineBuffer do
  @moduledoc "Linear, bounded JSON-line buffering without rescanning previous chunks."
  defstruct chunks: [], bytes: 0, dropping?: false

  def new, do: %__MODULE__{}
  def pending?(buffer), do: buffer.bytes > 0

  def push(buffer, chunk, limit), do: scan(buffer, chunk, limit, [])

  defp scan(buffer, "", _limit, lines), do: {Enum.reverse(lines), buffer}

  defp scan(buffer, chunk, limit, lines) do
    case :binary.match(chunk, "\n") do
      {index, 1} ->
        <<part::binary-size(^index), _newline, rest::binary>> = chunk
        {buffer, overflow?} = append(buffer, part, limit)
        lines = if overflow?, do: [:overflow | lines], else: lines
        lines = if buffer.dropping?, do: lines, else: [assemble(buffer) | lines]
        scan(new(), rest, limit, lines)

      :nomatch ->
        {buffer, overflow?} = append(buffer, chunk, limit)
        {Enum.reverse(if(overflow?, do: [:overflow | lines], else: lines)), buffer}
    end
  end

  defp append(%{dropping?: true} = buffer, _part, _limit), do: {buffer, false}

  defp append(buffer, part, limit) do
    bytes = buffer.bytes + byte_size(part)

    if bytes > limit do
      {%__MODULE__{dropping?: true}, true}
    else
      {%{buffer | chunks: [part | buffer.chunks], bytes: bytes}, false}
    end
  end

  defp assemble(buffer), do: buffer.chunks |> Enum.reverse() |> IO.iodata_to_binary()
end
