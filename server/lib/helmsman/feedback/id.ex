defmodule Helmsman.Feedback.Id do
  @moduledoc """
  Feedback IDs (`KEY-N#S`): the task ID (`Helmsman.Tasks.Ident`) and the
  feedback number in the task, a positive integer without leading zeros.
  """

  alias Helmsman.Tasks.Ident

  # The `integer` column's maximum: larger numbers cannot exist.
  @max_seq 2_147_483_647

  @doc """
  Parses a feedback ID into the canonical task ID and the feedback number.

      iex> Helmsman.Feedback.Id.parse("bos-12#3")
      {:ok, "BOS-12", 3}

      iex> Helmsman.Feedback.Id.parse("BOS-12#03")
      {:error, :not_found}
  """
  @spec parse(term()) :: {:ok, String.t(), pos_integer()} | {:error, :not_found}
  def parse(id) when is_binary(id) do
    with [task_part, seq_part] <- String.split(id, "#"),
         true <- Regex.match?(~r/\A[1-9][0-9]*\z/, seq_part),
         seq when seq <= @max_seq <- String.to_integer(seq_part),
         {:ok, ident, _key, _task_seq} <- Ident.parse(task_part) do
      {:ok, ident, seq}
    else
      _ -> {:error, :not_found}
    end
  end

  def parse(_id), do: {:error, :not_found}

  @doc "Builds the ID of feedback number `seq` of the task `ident`."
  @spec build(String.t(), pos_integer()) :: String.t()
  def build(ident, seq) when is_binary(ident) and is_integer(seq) and seq > 0,
    do: "#{ident}##{seq}"
end
