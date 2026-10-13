defmodule Helmsman.Tasks.VerifiedSnapshotTest do
  # add-squads 3.1: every move to `verified` records the assignee side of
  # the moment (decision 11).
  use Helmsman.DataCase, async: true

  import Helmsman.ProjectsFixtures
  import Helmsman.PullRequestFixtures
  import Helmsman.RunsFixtures
  import Helmsman.SquadsFixtures

  alias Helmsman.{FakeGitHub, Tasks}
  alias Helmsman.GitHub.PullRequests
  alias Helmsman.Tasks.TaskEvent

  defp events(task),
    do: Repo.all(from(e in TaskEvent, where: e.task_id == ^task.id, order_by: e.id))

  defp verify(scope, task, assignee) do
    {:ok, _} = Tasks.update(scope, task.ident, %{assignee: assignee, start: false})

    for to <- [:in_progress, :done],
        do: {:ok, _} = Tasks.transition(scope, task.ident, to)

    {:ok, _} = Tasks.transition(scope, task.ident, :verified)
    events(task)
  end

  describe "the assignee side on the event" do
    setup do
      squads_fixture()
    end

    test "a squad: its identity, leader and members", ctx do
      task = task_fixture(ctx.alice_scope, ctx.project.key)
      evs = verify(ctx.carol_scope, task, "web-team")

      bob = human_actor(ctx.workspace, ctx.bob).id

      assert List.last(evs).assignee_side_ids ==
               [ctx.squad_actor.id, ctx.lead.id, ctx.fe.id, ctx.review.id, ctx.qa.id, bob]

      # Every other move records nothing.
      assert Enum.all?(Enum.drop(evs, -1), &is_nil(&1.assignee_side_ids))
    end

    test "an agent, a person, nobody", ctx do
      task = task_fixture(ctx.alice_scope, ctx.project.key)

      assert List.last(verify(ctx.carol_scope, task, "keel/dev")).assignee_side_ids == [
               ctx.agent.id
             ]

      task = task_fixture(ctx.alice_scope, ctx.project.key)
      bob = human_actor(ctx.workspace, ctx.bob)
      assert List.last(verify(ctx.carol_scope, task, bob.name)).assignee_side_ids == [bob.id]

      task = task_fixture(ctx.alice_scope, ctx.project.key)
      Repo.update_all(from(t in Tasks.Task, where: t.id == ^task.id), set: [status: :done])
      {:ok, _} = Tasks.transition(ctx.carol_scope, task.ident, :verified)
      assert List.last(events(task)).assignee_side_ids == []
    end
  end

  test "re-verifying records it too" do
    ctx = pr_fixture()
    fake = FakeGitHub.start()
    pushed_run(ctx, sha("c"), sha("0"))
    {:ok, _} = move(ctx.alice_scope, ctx.task, [:in_progress, :done, :verified])
    FakeGitHub.put_pull(fake, 1, %{head_ref: ctx.branch, head_sha: sha("d")})

    pr_row(ctx, %{
      number: 1,
      head_sha: sha("d"),
      merge_status: :stale,
      merge_reason: :head_changed
    })

    pushed_run(ctx, sha("d"), sha("c"))

    assert {:ok, _view} = PullRequests.reverify(ctx.alice_scope, ctx.task.ident)

    assert %TaskEvent{from_status: :verified, to_status: :verified, assignee_side_ids: side} =
             latest_verification(ctx.task)

    assert side == [ctx.agent.id]
  end
end
