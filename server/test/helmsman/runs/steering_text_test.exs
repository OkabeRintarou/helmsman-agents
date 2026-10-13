defmodule Helmsman.Runs.SteeringTextTest do
  # add-run-steering 1.3: the text pushed into the CLI (decision 4).
  use Helmsman.DataCase, async: true

  import Helmsman.ProjectsFixtures
  import Helmsman.RunsFixtures

  alias Helmsman.Feedback
  alias Helmsman.Runs.Steering

  setup do
    ctx = dispatch_fixture()
    task = task_fixture(ctx.alice_scope, ctx.project.key)
    alice = human_actor(ctx.workspace, ctx.alice)
    Map.merge(ctx, %{task: task, alice_actor: alice})
  end

  defp text(ctx, attrs) do
    {:ok, entry} = Feedback.add(ctx.alice_scope, ctx.task.ident, attrs)
    {Steering.text(entry), Feedback.view(entry).id}
  end

  test "a comment", ctx do
    {text, id} = text(ctx, %{content: "Use the other API"})

    assert text == """
           #{ctx.alice_actor.name} added #{id} (comment) to #{ctx.task.ident} while you are working on it:
           > Use the other API
           Take it into account in this run.\
           """
  end

  test "a question: the last line asks for an answer", ctx do
    {text, id} = text(ctx, %{kind: "question", content: "Why Redis?"})

    assert text == """
           #{ctx.alice_actor.name} added #{id} (question) to #{ctx.task.ident} while you are working on it:
           > Why Redis?
           It is a question for you: answer it with add_feedback (kind "answer").\
           """
  end

  test "several lines are each quoted", ctx do
    {text, _id} = text(ctx, %{content: "one\ntwo\r\n\nthree"})
    assert text =~ "\n> one\n> two\n> \n> three\nTake it into account in this run."
  end

  test "over 8 KB is cut with a note to read get_task", ctx do
    {text, _id} = text(ctx, %{content: String.duplicate("é", 5000)})
    [_head, quoted, note, last] = String.split(text, "\n")
    assert byte_size(quoted) <= 8192 + 2
    assert String.valid?(quoted)
    assert note == "> …(truncated; read the full text with get_task)"
    assert last == "Take it into account in this run."
  end
end
