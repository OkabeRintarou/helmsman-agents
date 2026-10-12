defmodule HelmsmanWeb.FeedbackTimelineTest do
  use ExUnit.Case, async: true

  alias HelmsmanWeb.FeedbackTimeline

  doctest FeedbackTimeline

  defp view(seq, thread, kind, status \\ "active", by \\ nil) do
    %{
      id: "BOS-12##{seq}",
      seq: seq,
      thread_seq: thread,
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
