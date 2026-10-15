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
      reply_to: nil,
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

  describe "tree/1 (add-nested-feedback-replies D1–D4, D7)" do
    # `reply_to` names the replied record; `reply_root` stays the top root (unused here).
    defp to(view, target), do: Map.put(view, :reply_to, target && "BOS-12##{target}")

    # {thread's current seq, depth, label?, replies}
    defp shape(nodes) do
      Enum.map(nodes, fn n -> {n.current.seq, n.depth, n.label?, shape(n.replies)} end)
    end

    defp chain(n) do
      [view(1, 1, "comment") | for(i <- 2..n, do: to(view(i, i, "comment"), i - 1))]
    end

    test "多层回复: under the actual target, in thread order, no labels" do
      feedback = [
        view(1, 1, "comment"),
        to(view(2, 2, "comment"), 1),
        to(view(3, 3, "comment"), 2),
        to(view(4, 4, "comment"), 1)
      ]

      assert shape(FeedbackTimeline.tree(feedback)) ==
               [{1, 0, false, [{2, 1, false, [{3, 2, false, []}]}, {4, 1, false, []}]}]
    end

    test "超过 3 层: deeper replies sit at depth 3 under the depth-2 ancestor, labelled" do
      assert shape(FeedbackTimeline.tree(chain(6))) ==
               [
                 {1, 0, false,
                  [
                    {2, 1, false,
                     [
                       {3, 2, false, [{4, 3, false, []}, {5, 3, true, []}, {6, 3, true, []}]}
                     ]}
                  ]}
               ]
    end

    for {depth, flattened} <- [{4, [5]}, {5, [5, 6]}, {6, [5, 6, 7]}] do
      test "a chain #{depth} deep flattens #{inspect(flattened)}" do
        nodes = FeedbackTimeline.tree(chain(unquote(depth) + 1))
        [%{replies: [%{replies: [%{replies: level3}]}]}] = nodes
        assert Enum.map(level3, & &1.current.seq) == [4 | unquote(flattened)]
        assert Enum.all?(level3, &(&1.depth == 3 and &1.replies == []))

        assert Enum.map(level3, & &1.label?) == [
                 false | Enum.map(unquote(flattened), fn _ -> true end)
               ]
      end
    end

    test "flattened replies merge with the depth-3 siblings in thread order" do
      feedback = chain(5) ++ [to(view(6, 6, "comment"), 3)]
      [%{replies: [%{replies: [%{replies: level3}]}]}] = FeedbackTimeline.tree(feedback)
      assert Enum.map(level3, &{&1.current.seq, &1.label?}) == [{4, false}, {5, true}, {6, false}]
    end

    test "回复早期版本: the reply hangs under the thread, without a label" do
      feedback = [
        view(1, 1, "comment", "superseded", 3),
        to(view(2, 2, "comment"), 1),
        view(3, 1, "comment")
      ]

      assert [%{current: %{seq: 3}, history: [%{seq: 1}], replies: [reply]}] =
               FeedbackTimeline.tree(feedback)

      assert {reply.current.seq, reply.depth, reply.label?} == {2, 1, false}
    end

    test "a revised reply keeps its place and its target" do
      feedback = [
        view(1, 1, "comment"),
        to(view(2, 2, "comment", "superseded", 4), 1),
        view(3, 3, "comment"),
        to(view(4, 2, "comment"), 1)
      ]

      assert [%{replies: [reply]}, %{current: %{seq: 3}}] = FeedbackTimeline.tree(feedback)
      assert reply.current.seq == 4
      assert Enum.map(reply.history, & &1.seq) == [2]
    end

    test "a missing target makes a labelled root" do
      feedback = [to(view(2, 2, "comment"), 1), view(3, 3, "comment")]
      assert shape(FeedbackTimeline.tree(feedback)) == [{2, 0, true, []}, {3, 0, false, []}]
      assert FeedbackTimeline.tree([]) == []
    end

    test "roots and siblings in thread order, whatever the input order" do
      feedback =
        Enum.shuffle([
          view(1, 1, "comment"),
          view(2, 2, "question"),
          to(view(5, 5, "comment"), 1),
          to(view(3, 3, "answer"), 2),
          to(view(4, 4, "comment"), 1)
        ])

      assert shape(FeedbackTimeline.tree(feedback)) ==
               [
                 {1, 0, false, [{4, 1, false, []}, {5, 1, false, []}]},
                 {2, 0, false, [{3, 1, false, []}]}
               ]
    end

    test "reply_count counts every level" do
      [root] = FeedbackTimeline.tree(chain(6))
      assert FeedbackTimeline.reply_count(root) == 5
    end

    test "2,000 records and a 1,000-deep chain" do
      wide =
        [view(1, 1, "comment")] ++
          for(i <- 2..2000, do: to(view(i, i, "comment"), Enum.random(1..(i - 1))))

      tree = FeedbackTimeline.tree(wide)
      assert Enum.reduce(tree, 0, &(&2 + 1 + FeedbackTimeline.reply_count(&1))) == 2000
      assert max_depth(tree) <= 3

      [root] = FeedbackTimeline.tree(chain(1000))
      assert FeedbackTimeline.reply_count(root) == 999
      [%{replies: [%{replies: [%{replies: level3}]}]}] = [root]
      assert length(level3) == 997
      assert Enum.map(level3, & &1.current.seq) == Enum.to_list(4..1000)
    end

    defp max_depth(nodes),
      do: nodes |> Enum.map(&max(&1.depth, max_depth(&1.replies))) |> Enum.max(fn -> 0 end)
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
