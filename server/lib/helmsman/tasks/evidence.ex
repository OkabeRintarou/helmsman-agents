defmodule Helmsman.Tasks.Evidence do
  @moduledoc """
  The evidence a transition may carry (designs/05 §4): a comment, commits
  and a test result. Validated and normalized before the transition's
  transaction starts, so invalid input never takes a lock.

    * `comment` - at most 10000 characters; `nil` or `""` for none
    * `commits` - 7 to 64 hexadecimal characters each, downcased,
      duplicates removed (first occurrence kept)
    * `tests` - `%{command, passed, summary}`: `passed` a boolean,
      `command` and `summary` strings of at most 2000 characters each.
      Only these three keys are kept, stored with string keys.

  Keys may be atoms or strings.
  """

  @max_comment 10_000
  @max_test_text 2_000
  @commit ~r/\A[0-9a-fA-F]{7,64}\z/

  @type tests :: %{String.t() => String.t() | boolean()}
  @type t :: %{comment: String.t() | nil, commits: [String.t()], tests: tests() | nil}
  @type reason ::
          {:invalid_comment, :too_long | :not_a_string}
          | {:invalid_commits, term()}
          | {:invalid_tests, atom() | {atom(), atom()}}

  @doc """
  Normalizes the evidence in `opts` (a map or keyword list).

      iex> Helmsman.Tasks.Evidence.normalize(%{commits: ["ABC1234", "abc1234"]})
      {:ok, %{comment: nil, commits: ["abc1234"], tests: nil}}
  """
  @spec normalize(map() | keyword()) :: {:ok, t()} | {:error, reason()}
  def normalize(opts) when is_list(opts), do: opts |> Map.new() |> normalize()

  def normalize(opts) when is_map(opts) do
    with {:ok, comment} <- comment(fetch(opts, :comment)),
         {:ok, commits} <- commits(fetch(opts, :commits)),
         {:ok, tests} <- tests(fetch(opts, :tests)) do
      {:ok, %{comment: comment, commits: commits, tests: tests}}
    end
  end

  defp comment(value) when value in [nil, ""], do: {:ok, nil}

  defp comment(value) when is_binary(value) do
    if String.length(value) <= @max_comment,
      do: {:ok, value},
      else: {:error, {:invalid_comment, :too_long}}
  end

  defp comment(_value), do: {:error, {:invalid_comment, :not_a_string}}

  defp commits(nil), do: {:ok, []}

  defp commits(list) when is_list(list) do
    # `Enum.split_with/2` instead of `Enum.find/2`: a `nil` item must be
    # reported, not mistaken for "nothing found".
    case Enum.split_with(list, &commit?/1) do
      {valid, []} -> {:ok, valid |> Enum.map(&String.downcase/1) |> Enum.uniq()}
      {_valid, [bad | _]} -> {:error, {:invalid_commits, bad}}
    end
  end

  defp commits(other), do: {:error, {:invalid_commits, other}}

  defp commit?(value), do: is_binary(value) and Regex.match?(@commit, value)

  defp tests(nil), do: {:ok, nil}

  defp tests(map) when is_map(map) and not is_struct(map) do
    with {:ok, passed} <- passed(fetch(map, :passed)),
         {:ok, command} <- test_text(:command, fetch(map, :command)),
         {:ok, summary} <- test_text(:summary, fetch(map, :summary)) do
      {:ok, %{"command" => command, "passed" => passed, "summary" => summary}}
    end
  end

  defp tests(_other), do: {:error, {:invalid_tests, :not_an_object}}

  defp passed(value) when is_boolean(value), do: {:ok, value}
  defp passed(_value), do: {:error, {:invalid_tests, {:passed, :not_a_boolean}}}

  defp test_text(key, value) when is_binary(value) do
    if String.length(value) <= @max_test_text,
      do: {:ok, value},
      else: {:error, {:invalid_tests, {key, :too_long}}}
  end

  defp test_text(key, _value), do: {:error, {:invalid_tests, {key, :not_a_string}}}

  defp fetch(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end
end
