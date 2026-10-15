defmodule HelmsmanWeb.FeedbackComponentsTest do
  # add-nested-feedback-replies D3–D6 (the reply tree) with the view shape of
  # add-feedback-replies D4, built by hand so each target state is rendered in isolation;
  # the task page tests cover the same through `Feedback.add/3`.
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias HelmsmanWeb.FeedbackComponents

  defp entry(seq, opts \\ []) do
    thread = Keyword.get(opts, :thread, seq)

    %{
      id: "BOS-1##{seq}",
      seq: seq,
      thread_seq: thread,
      kind: Keyword.get(opts, :kind, "comment"),
      content: "内容 #{seq}",
      author: %{name: Keyword.get(opts, :author, "alice"), kind: "human"},
      mentions: [],
      status: Keyword.get(opts, :status, "active"),
      supersedes: nil,
      superseded_by: opts[:superseded_by] && "BOS-1##{opts[:superseded_by]}",
      dispatch: [],
      steer: nil,
      at: ~U[2026-10-14 08:00:00Z],
      reply_to: opts[:reply_to] && "BOS-1##{opts[:reply_to]}",
      reply_root: opts[:root] && "BOS-1##{opts[:root]}",
      target: opts[:target]
    }
  end

  defp target(seq, author, summary, status \\ "active"),
    do: %{
      id: "BOS-1##{seq}",
      seq: seq,
      author: %{name: author, kind: "human"},
      summary: summary,
      status: status
    }

  defp render_timeline(feedback, opts \\ []) do
    html = Map.new(feedback, &{&1.seq, Phoenix.HTML.raw("<p>#{&1.content}</p>")})

    render_component(&FeedbackComponents.timeline/1,
      feedback: feedback,
      html: html,
      scope: %{},
      revisable: MapSet.new(),
      can_feedback?: Keyword.get(opts, :can_feedback?, true),
      fresh_after: 1_000
    )
    |> LazyHTML.from_fragment()
  end

  defp ids(doc, selector), do: doc |> LazyHTML.query(selector) |> LazyHTML.attribute("id")
  defp text(doc, selector), do: doc |> LazyHTML.query(selector) |> LazyHTML.text()

  defp replies(doc, ts), do: ids(doc, "#feedback-thread-#{ts}-replies > ol > li > article")

  # A chain: #1 ← #2 ← … ← #n, each by a different author.
  defp chain(n) do
    [entry(1, author: "a1")] ++
      for i <- 2..n,
          do:
            entry(i,
              author: "a#{i}",
              reply_to: i - 1,
              target: target(i - 1, "a#{i - 1}", "首行 #{i - 1}")
            )
  end

  test "多层回复: nested under the actual target, no 回复 @… line" do
    doc =
      render_timeline([
        entry(1, author: "alice"),
        entry(2, author: "bob", reply_to: 1, target: target(1, "alice", "已复现")),
        entry(3, author: "carol", reply_to: 2, target: target(2, "bob", "同意")),
        entry(4, reply_to: 1, target: target(1, "alice", "已复现")),
        entry(5)
      ])

    assert ids(doc, "#feedback-threads > li > article") == ["feedback-1", "feedback-5"]
    assert replies(doc, 1) == ["feedback-2", "feedback-4"]
    assert replies(doc, 2) == ["feedback-3"]
    assert text(doc, "#feedback-title") =~ "5"
    assert LazyHTML.query(doc, "[id$=-reply-to]") |> Enum.empty?()
  end

  test "each level is indented with a guide line; depth never exceeds 3" do
    doc = render_timeline(chain(6))

    for ts <- [1, 2, 3] do
      [class] =
        doc
        |> LazyHTML.query("#feedback-thread-#{ts}-replies > ol")
        |> LazyHTML.attribute("class")

      assert class =~ "pl-3" and class =~ "sm:pl-6" and class =~ "border-l"
    end

    depths = doc |> LazyHTML.query("li[data-depth]") |> LazyHTML.attribute("data-depth")
    assert Enum.max(Enum.map(depths, &String.to_integer/1)) == 3
    assert replies(doc, 3) == ["feedback-4", "feedback-5", "feedback-6"]
    refute LazyHTML.query(doc, "#feedback-thread-4-replies") |> Enum.any?()
  end

  test "超过 3 层: only the flattened replies say whom they reply to" do
    doc = render_timeline(chain(6))

    refute LazyHTML.query(doc, "#feedback-4-reply-to") |> Enum.any?()
    assert text(doc, "#feedback-5-reply-to [data-reply-label]") == "回复 @a4 #4"
    assert text(doc, "#feedback-5-reply-to [data-target-summary]") =~ "首行 4"

    assert doc |> LazyHTML.query("#feedback-5-reply-to") |> LazyHTML.attribute("href") == [
             "#feedback-4"
           ]

    assert text(doc, "#feedback-6-reply-to [data-reply-label]") == "回复 @a5 #5"
  end

  test "a missing target: a root saying 回复 #n, not a link" do
    doc = render_timeline([entry(2, reply_to: 1), entry(3)])

    assert ids(doc, "#feedback-threads > li > article") == ["feedback-2", "feedback-3"]
    assert text(doc, "#feedback-2-reply-to[data-target-missing] [data-reply-label]") == "回复 #1"
    assert doc |> LazyHTML.query("#feedback-2-reply-to") |> LazyHTML.attribute("href") == []
  end

  test "a flattened reply to a revised target shows its current version and 已修订" do
    feedback =
      chain(4) ++
        [entry(5, reply_to: 4, target: target(6, "a4", "修订后的首行", "superseded"))]

    doc = render_timeline(feedback)

    assert doc |> LazyHTML.query("#feedback-5-reply-to") |> LazyHTML.attribute("href") == [
             "#feedback-6"
           ]

    assert text(doc, "#feedback-5-reply-to [data-reply-label]") == "回复 @a4 #6"
    assert text(doc, "#feedback-5 [data-target-revised]") =~ "已修订"
    assert text(doc, "#feedback-5 [data-target-summary]") =~ "修订后的首行"
  end

  test "an answer under its question has no line; a flattened one reads as its answer" do
    doc =
      render_timeline(
        chain(3) ++
          [
            entry(4,
              kind: "question",
              author: "keel/dev",
              reply_to: 3,
              target: target(3, "a3", "x")
            ),
            entry(5, kind: "answer", reply_to: 4, target: target(4, "keel/dev", "A 还是 B？"))
          ]
      )

    assert replies(doc, 3) == ["feedback-4", "feedback-5"]
    assert text(doc, "#feedback-5-reply-to [data-reply-label]") == "回答 @keel/dev #4 的提问"
    assert LazyHTML.query(doc, "#feedback-5-reply-to[data-answer]") |> Enum.any?()
  end

  test "folding: counts every level; a root's replies start open, a reply's past 10 folded" do
    many = for i <- 3..13, do: entry(i, reply_to: 2, target: target(2, "bob", "x"))
    few = for i <- 15..24, do: entry(i, reply_to: 14, target: target(14, "bob", "x"))

    doc =
      render_timeline(
        [
          entry(1),
          entry(2, reply_to: 1, target: target(1, "alice", "x")),
          entry(14, reply_to: 1, target: target(1, "alice", "x"))
        ] ++
          many ++ few
      )

    details = fn ts -> LazyHTML.query(doc, "#feedback-thread-#{ts}-replies") end
    assert details.(1) |> LazyHTML.attribute("data-count") == ["23"]
    assert details.(1) |> LazyHTML.attribute("open") == [""]
    assert details.(2) |> LazyHTML.attribute("data-count") == ["11"]
    assert details.(2) |> LazyHTML.attribute("open") == []
    assert details.(14) |> LazyHTML.attribute("open") == [""]
    assert text(doc, "#feedback-thread-2-toggle") =~ "展开 11 条回复"
    assert text(doc, "#feedback-thread-2-toggle") =~ "收起 11 条回复"
    [mounted] = details.(2) |> LazyHTML.attribute("phx-mounted")
    assert mounted =~ "ignore_attrs" and mounted =~ "open"
  end

  test "回复 on every active record, none on earlier versions or for readers" do
    feedback = [
      entry(1, kind: "question"),
      entry(2, status: "superseded", superseded_by: 3),
      entry(3, thread: 2)
    ]

    doc = render_timeline(feedback)
    assert ids(doc, "button[id$=-reply]") == ["feedback-1-reply", "feedback-3-reply"]
    assert ids(doc, "button[id$=-answer]") == ["feedback-1-answer"]

    [click] = doc |> LazyHTML.query("#feedback-3-reply") |> LazyHTML.attribute("phx-click")
    assert click =~ ~s("mode":"reply")
    assert click =~ ~s("target":"BOS-1#3")

    doc = render_timeline(feedback, can_feedback?: false)
    assert ids(doc, "button[id$=-reply]") == []
  end
end
