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

  @type node_ :: %{
          current: map(),
          history: [map()],
          depth: 0..3,
          label?: boolean(),
          replies: [node_()]
        }

  @max_depth 3

  @doc """
  The threads as a reply tree (add-nested-feedback-replies D1–D4, D7).

  A thread's parent is the thread of the record its current version replies to
  (`reply_to`, an earlier version included). A thread without `reply_to`, or whose
  target is not in `feedback`, is a root. Roots and siblings are in thread order.
  Depth is at most 3: a deeper reply shows under its depth-2 ancestor, among that
  ancestor's other replies. `label?` is true when the shown parent is not the thread
  the record replies to (flattened, or the target is missing): only then does the
  card say whom it replies to.

  A reply's target is always an earlier record and the target of a thread never
  changes (revisions keep it), so a parent's `thread_seq` is smaller than its
  child's: one pass in thread order computes every depth, and the tree has no cycle.
  """
  @spec tree([map()]) :: [node_()]
  def tree(feedback) do
    threads = threads(feedback)
    thread_of = Map.new(feedback, &{&1.seq, &1.thread_seq})

    # thread_seq => %{thread, parent (actual), depth, a2 (depth-2 ancestor), missing?}
    info =
      Enum.reduce(threads, %{}, fn thread, info ->
        Map.put(info, thread.current.thread_seq, place(thread, info, thread_of))
      end)

    shown_parent = fn %{parent: parent, depth: depth, a2: a2} ->
      if depth > @max_depth, do: a2, else: parent
    end

    children =
      info
      |> Map.values()
      |> Enum.filter(& &1.parent)
      |> Enum.group_by(shown_parent)
      |> Map.new(fn {parent, kids} ->
        {parent, Enum.sort_by(kids, & &1.thread.current.thread_seq)}
      end)

    threads
    |> Enum.map(&info[&1.current.thread_seq])
    |> Enum.filter(&is_nil(&1.parent))
    |> Enum.map(&build(&1, 0, nil, children))
  end

  # thread_seq => %{thread, parent (the actual one), depth, a2 (the depth-2 ancestor),
  # missing? (its target is not in the timeline)}; `info` has every earlier thread.
  defp place(thread, info, thread_of) do
    ts = thread.current.thread_seq
    target = seq_of(thread.current[:reply_to])
    parent = target && thread_of[target]
    parent = if parent && parent < ts && Map.has_key?(info, parent), do: parent
    depth = if parent, do: info[parent].depth + 1, else: 0

    %{
      thread: thread,
      parent: parent,
      depth: depth,
      a2: depth_2_ancestor(ts, depth, parent && info[parent]),
      missing?: target != nil and parent == nil
    }
  end

  defp depth_2_ancestor(_ts, depth, _parent) when depth < 2, do: nil
  defp depth_2_ancestor(ts, 2, _parent), do: ts
  defp depth_2_ancestor(_ts, _depth, parent), do: parent.a2

  defp build(entry, depth, shown, children) do
    ts = entry.thread.current.thread_seq

    entry.thread
    |> Map.merge(%{
      depth: depth,
      label?: entry.missing? or (shown != nil and shown != entry.parent),
      replies:
        children
        |> Map.get(ts, [])
        |> Enum.map(&build(&1, min(depth + 1, @max_depth), ts, children))
    })
  end

  @doc "The number of replies shown under a node of `tree/1`, at every level."
  @spec reply_count(node_()) :: non_neg_integer()
  def reply_count(%{replies: replies}),
    do: Enum.reduce(replies, 0, &(&2 + 1 + reply_count(&1)))

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
