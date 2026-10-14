defmodule HelmsmanWeb.FeedbackTimelineTest do
  use ExUnit.Case, async: true

  alias HelmsmanWeb.FeedbackTimeline

  doctest FeedbackTimeline

  defp view(seq, thread, kind, status \\ "active", by \\ nil) do
    %{
      id: "BOS-12##{seq}",
      seq: seq,
      thread_seq: thread,
      reply_root: nil,
      kind: kind,
      status: status,
      superseded_by: by && "BOS-12##{by}"
    }
  end

  defp seqs(threads),
    do: Enum.map(threads, &{&1.current.seq, Enum.map(&1.history, fn h -> h.seq end)})

  test "threads in thread order, earlier versions under the active one (线索与早期版本)" do
    feedback = [
      view(1, 1, "comment"),
      view(2, 2, "question", "superseded", 4),
      view(3, 3, "answer"),
      view(4, 2, "question")
    ]

    assert seqs(FeedbackTimeline.threads(feedback)) == [{1, []}, {4, [2]}, {3, []}]
  end

  test "several revisions: earlier versions newest first" do
    feedback = [
      view(1, 1, "comment", "superseded", 2),
      view(2, 1, "comment", "superseded", 5),
      view(3, 3, "review"),
      view(5, 1, "comment")
    ]

    assert seqs(FeedbackTimeline.threads(feedback)) == [{5, [2, 1]}, {3, []}]
  end

  test "no feedback, no threads" do
    assert FeedbackTimeline.threads([]) == []
  end

  describe "tree/1 (add-feedback-replies D5)" do
    defp reply(view, root), do: Map.put(view, :reply_root, root && "BOS-12##{root}")

    defp shape(tree) do
      Enum.map(tree, fn root ->
        {root.current.seq, Enum.map(root.replies, & &1.current.seq)}
      end)
    end

    test "replies, and replies to replies, sit under their root in thread order" do
      feedback = [
        view(1, 1, "comment"),
        view(2, 2, "question"),
        reply(view(3, 3, "comment"), 1),
        reply(view(4, 4, "answer"), 2),
        reply(view(5, 5, "comment"), 1),
        view(6, 6, "review")
      ]

      assert shape(FeedbackTimeline.tree(feedback)) == [{1, [3, 5]}, {2, [4]}, {6, []}]
    end

    test "a revised root and a revised reply keep their place" do
      feedback = [
        view(1, 1, "comment", "superseded", 3),
        reply(view(2, 2, "comment", "superseded", 4), 1),
        view(3, 1, "comment"),
        reply(view(4, 2, "comment"), 1)
      ]

      assert [%{current: %{seq: 3}, history: [%{seq: 1}], replies: [reply]}] =
               FeedbackTimeline.tree(feedback)

      assert reply.current.seq == 4
      assert Enum.map(reply.history, & &1.seq) == [2]
    end

    test "a reply whose root is missing shows as a root; no reply_root, no nesting" do
      feedback = [reply(view(2, 2, "comment"), 1), view(3, 3, "comment")]
      assert shape(FeedbackTimeline.tree(feedback)) == [{2, []}, {3, []}]
      assert FeedbackTimeline.tree([]) == []
    end
  end

  test "the last active question" do
    feedback = [
      view(1, 1, "question"),
      view(2, 2, "question", "superseded", 3),
      view(3, 2, "question"),
      view(4, 4, "comment")
    ]

    assert FeedbackTimeline.last_open_question(feedback).seq == 3
    assert FeedbackTimeline.last_open_question([view(1, 1, "comment")]) == nil
  end
end
