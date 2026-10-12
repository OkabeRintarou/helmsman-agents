defmodule HelmsmanProtocol.Event do
  @moduledoc "Event protocol payload."
  use HelmsmanProtocol.Schema

  @types ~w(text thinking tool_call tool_result usage session result error status)a
  @data %{
    text: HelmsmanProtocol.Event.Text,
    thinking: HelmsmanProtocol.Event.Thinking,
    tool_call: HelmsmanProtocol.Event.ToolCall,
    tool_result: HelmsmanProtocol.Event.ToolResult,
    usage: HelmsmanProtocol.Event.Usage,
    session: HelmsmanProtocol.Event.Session,
    result: HelmsmanProtocol.Event.Result,
    error: HelmsmanProtocol.Event.Error,
    status: HelmsmanProtocol.Event.Status
  }
  field(:seq, :pos_integer)

  field(:type, {:enum, @types})

  field(:data, {:variant, :type, @data})
  field(:at, :datetime)
  @spec types() :: [atom()]
  def types, do: @types

  @doc "Truncates valid UTF-8 text at a code point boundary, measuring bytes."
  @spec truncate(String.t(), non_neg_integer()) :: {String.t(), boolean()}
  def truncate(text, max_bytes)
      when is_binary(text) and is_integer(max_bytes) and max_bytes >= 0 do
    if byte_size(text) <= max_bytes do
      {text, false}
    else
      prefix = binary_part(text, 0, max_bytes)
      {valid_prefix(prefix), true}
    end
  end

  defp valid_prefix(prefix) do
    if String.valid?(prefix),
      do: prefix,
      else: valid_prefix(binary_part(prefix, 0, byte_size(prefix) - 1))
  end
end
