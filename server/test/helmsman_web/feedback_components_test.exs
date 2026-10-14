defmodule HelmsmanWeb.FeedbackComponentsTest do
  # add-feedback-replies D5 with the view shape of its design D4, built by hand so each
  # target state is rendered in isolation; the task page tests cover the same through
  # `Feedback.add/3`.
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

  test "replies sit one level under their root and say whom they reply to" do
    doc =
      render_timeline([
        entry(1, author: "alice"),
        entry(2, author: "bob", reply_to: 1, root: 1, target: target(1, "alice", "已复现")),
        entry(3, author: "carol", reply_to: 2, root: 1, target: target(2, "bob", "同意")),
        entry(4)
      ])

    assert ids(doc, "#feedback-threads > li > article") == ["feedback-1", "feedback-4"]

    assert ids(doc, "#feedback-thread-1-replies > li > article") == [
             "feedback-2",
             "feedback-3"
           ]

    assert text(doc, "#feedback-title") =~ "4"
    refute LazyHTML.query(doc, "#feedback-1-reply-to") |> Enum.any?()

    link = LazyHTML.query(doc, "#feedback-3-reply-to")
    assert LazyHTML.attribute(link, "href") == ["#feedback-2"]
    assert LazyHTML.attribute(link, "data-reply-to") == ["BOS-1#2"]
    assert text(doc, "#feedback-3-reply-to [data-reply-label]") == "回复 @bob #2"
    assert text(doc, "#feedback-3-reply-to [data-target-summary]") =~ "同意"
    assert text(doc, "#feedback-2-reply-to [data-reply-label]") == "回复 @alice #1"
    refute LazyHTML.query(doc, "#feedback-2 [data-target-revised]") |> Enum.any?()
  end

  test "a revised target shows its current version and 已修订" do
    doc =
      render_timeline([
        entry(1, status: "superseded", superseded_by: 3),
        entry(2, reply_to: 1, root: 1, target: target(3, "alice", "修订后的首行", "superseded")),
        entry(3, thread: 1)
      ])

    assert ids(doc, "#feedback-thread-1-replies > li > article") == ["feedback-2"]

    assert LazyHTML.query(doc, "#feedback-2-reply-to") |> LazyHTML.attribute("href") == [
             "#feedback-3"
           ]

    assert text(doc, "#feedback-2-reply-to [data-reply-label]") == "回复 @alice #3"
    assert text(doc, "#feedback-2 [data-target-revised]") =~ "已修订"
    assert text(doc, "#feedback-2 [data-target-summary]") =~ "修订后的首行"
  end

  test "an answer to a question reads as its answer" do
    doc =
      render_timeline([
        entry(1, kind: "question", author: "keel/dev"),
        entry(2, kind: "answer", reply_to: 1, root: 1, target: target(1, "keel/dev", "A 还是 B？")),
        entry(3, kind: "comment", reply_to: 1, root: 1, target: target(1, "keel/dev", "A 还是 B？"))
      ])

    assert text(doc, "#feedback-2-reply-to [data-reply-label]") == "回答 @keel/dev #1 的提问"
    assert LazyHTML.query(doc, "#feedback-2-reply-to[data-answer]") |> Enum.any?()
    assert text(doc, "#feedback-3-reply-to [data-reply-label]") == "回复 @keel/dev #1"
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
