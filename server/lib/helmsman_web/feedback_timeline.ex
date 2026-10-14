defmodule HelmsmanWeb.FeedbackTimeline do
  @moduledoc """
  The feedback timeline of a task page (design D4), from the `feedback` list of
  `Helmsman.Tasks.detail/1` (every record, superseded ones included). Pure.
  """

  @type thread :: %{current: map(), history: [map()]}

  @doc """
  One thread per `thread_seq`, in that order: `current` is its active record,
  `history` its superseded ones, the most recent first.
  """
  @spec threads([map()]) :: [thread()]
  def threads(feedback) do
    feedback
    |> Enum.group_by(& &1.thread_seq)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(fn {_thread, views} ->
      views = Enum.sort_by(views, & &1.seq, :desc)
      current = Enum.find(views, &(&1.status == "active")) || hd(views)
      %{current: current, history: Enum.reject(views, &(&1 == current))}
    end)
  end

  @doc """
  The threads grouped one level deep (add-feedback-replies D5): roots in thread
  order, each with `replies`, the threads whose `reply_root` is that root, also in
  thread order. A reply whose root is missing shows as a root.
  """
  @spec tree([map()]) :: [%{current: map(), history: [map()], replies: [thread()]}]
  def tree(feedback) do
    threads = threads(feedback)
    roots = MapSet.new(threads, & &1.current.thread_seq)

    {replies, top} =
      Enum.split_with(threads, fn thread ->
        root = root_of(thread)
        root != nil and root != thread.current.thread_seq and MapSet.member?(roots, root)
      end)

    replies = Enum.group_by(replies, &root_of/1)
    Enum.map(top, &Map.put(&1, :replies, Map.get(replies, &1.current.thread_seq, [])))
  end

  defp root_of(%{current: current}), do: seq_of(current.reply_root)

  @doc "The last active question, or nil."
  @spec last_open_question([map()]) :: map() | nil
  def last_open_question(feedback) do
    feedback
    |> Enum.filter(&(&1.kind == "question" and &1.status == "active"))
    |> Enum.max_by(& &1.seq, fn -> nil end)
  end

  @doc """
  The number of a feedback ID (`"BOS-12#3"` → `3`), or nil.

      iex> HelmsmanWeb.FeedbackTimeline.seq_of("BOS-12#3")
      3
  """
  @spec seq_of(String.t() | nil) :: pos_integer() | nil
  def seq_of(nil), do: nil

  def seq_of(id) when is_binary(id) do
    with [_, seq] <- String.split(id, "#", parts: 2),
         {n, ""} <- Integer.parse(seq) do
      n
    else
      _ -> nil
    end
  end
end
