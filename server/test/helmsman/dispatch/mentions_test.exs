defmodule Helmsman.Dispatch.MentionsTest do
  # add-continuation-triggers 1.5: mention triggers and the outcomes kept
  # on the feedback (decisions 4, 10).
  use Helmsman.DataCase, async: true

  import Helmsman.AgentsFixtures
  import Helmsman.ProjectsFixtures
  import Helmsman.RunsFixtures

  alias Helmsman.Accounts.Scope
  alias Helmsman.Actors.Actor
  alias Helmsman.{Events, Feedback, Tx}
  alias Helmsman.Runs.Run
  alias Helmsman.Tasks.Task

  setup do
    ctx = dispatch_fixture()
    {bob, bob_scope} = member_scope_fixture(ctx.workspace)

    for {name, access} <- [
          {"keel/review", "workspace"},
          {"keel/qa", "workspace"},
          {"keel/c", "owner_only"}
        ],
        do: managed_agent_fixture(ctx.alice_scope, %{name: name, access: access})

    task = task_fixture(ctx.alice_scope, ctx.project.key)
    Map.merge(ctx, %{bob: bob, bob_scope: bob_scope, task: task})
  end

  defp agent(ctx, name), do: agent_actor(ctx.workspace, name)

  defp reply_run(task_id, agent) do
    Repo.one(
      from(r in Run,
        where:
          r.task_id == ^task_id and r.agent_id == ^agent.id and r.lane == :reply and
            r.status == :queued
      )
    )
  end

  test "mentioning a review agent (scenario)", ctx do
    {:ok, entry} = Feedback.add(ctx.alice_scope, ctx.task.ident, %{content: "@keel/review 请看一下"})

    assert [
             %{
               agent: "keel/review",
               trigger: "mention",
               result: "queued",
               reason: nil,
               run_id: id
             }
           ] =
             Feedback.view(entry).dispatch

    run = reply_run(ctx.task.id, agent(ctx, "keel/review"))
    assert run.id == id
    assert run.root_initiator_user_id == ctx.alice.id
    assert [%{"kind" => "mention", "feedback_id" => fid, "by_actor_id" => by}] = run.triggers
    assert fid == entry.id
    assert by == ctx.alice_scope.actor.id
  end

  test "a revision only counts the new mentions (scenario)", ctx do
    {:ok, entry} = Feedback.add(ctx.alice_scope, ctx.task.ident, %{content: "@keel/review 请看"})

    {:ok, revised} =
      Feedback.revise(ctx.alice_scope, Feedback.view(entry).id, %{
        content: "@keel/review @keel/qa 请看"
      })

    assert [%{agent: "keel/qa", trigger: "mention", result: "queued"}] =
             Feedback.view(revised).dispatch
  end

  test "a mention through a run on behalf of bob is refused (scenario)", ctx do
    run =
      run_fixture(ctx.agent, %{
        task_id: ctx.task.id,
        status: :running,
        capabilities: ["read", "write_task"],
        root_initiator_user_id: ctx.bob.id
      })

    {scope, _token} = run_scope_fixture(run)
    {:ok, entry} = Feedback.add(scope, ctx.task.ident, %{content: "@keel/c please check"})

    assert [%{agent: "keel/c", trigger: "mention", result: "skipped", reason: "unauthorized"}] =
             Feedback.view(entry).dispatch

    assert reply_run(ctx.task.id, agent(ctx, "keel/c")) == nil
  end

  test "a refused mention is kept and read back (scenario)", ctx do
    {:ok, entry} = Feedback.add(ctx.bob_scope, ctx.task.ident, %{content: "@keel/c 请看"})
    {:ok, read} = Feedback.get(ctx.bob_scope, Feedback.view(entry).id)

    assert [%{agent: "keel/c", trigger: "mention", result: "skipped", reason: "unauthorized"}] =
             Feedback.view(read).dispatch

    {:ok, [listed]} = Feedback.list(ctx.bob_scope, ctx.task.ident)
    assert Feedback.view(listed).dispatch == Feedback.view(read).dispatch
  end

  test "the system identity's note triggers nothing (scenario)", ctx do
    system =
      Repo.one!(
        from(a in Actor, where: a.workspace_id == ^ctx.workspace.id and a.kind == :system)
      )

    task = Repo.get!(Task, ctx.task.id)

    {:ok, {entry, _task}} =
      Tx.run(fn ->
        Feedback.insert_locked(task, %Scope{actor: system}, %{content: "cc @keel/dev"})
      end)

    {:ok, read} = Feedback.get(ctx.alice_scope, Feedback.Id.build(task.ident, entry.seq))
    assert Feedback.view(read).dispatch == []
    assert reply_run(task.id, ctx.agent) == nil
  end

  test "the notification carries the outcomes (scenario)", ctx do
    Events.subscribe(Events.topic(:task, ctx.task.id))
    {:ok, _entry} = Feedback.add(ctx.alice_scope, ctx.task.ident, %{content: "@keel/review 请看"})

    assert_receive {:feedback_added, %{dispatch: [item]}}
    assert %{agent: "keel/review", trigger: "mention", result: "queued", run_id: id} = item
    assert is_integer(id)
  end

  test "two agents in one record: by actor ID; the author itself never", ctx do
    {:ok, entry} =
      Feedback.add(ctx.alice_scope, ctx.task.ident, %{content: "@keel/qa and @keel/review"})

    ids = Enum.map(Feedback.view(entry).dispatch, & &1.agent)
    expected = Enum.sort_by(["keel/qa", "keel/review"], &agent(ctx, &1).id)
    assert ids == expected

    review = agent(ctx, "keel/review")

    run =
      run_fixture(review, %{
        task_id: ctx.task.id,
        status: :running,
        capabilities: ["read", "write_task"]
      })

    {scope, _token} = run_scope_fixture(run)
    {:ok, entry} = Feedback.add(scope, ctx.task.ident, %{content: "@keel/review here"})
    assert Feedback.view(entry).dispatch == []
  end

  test "people and external agents are only marked", ctx do
    Helmsman.ApiTokensFixtures.agent_fixture(ctx.workspace, ctx.alice, "keel/ext")
    bob = ctx.bob_scope.actor.name

    {:ok, entry} = Feedback.add(ctx.alice_scope, ctx.task.ident, %{content: "@#{bob} @keel/ext"})
    view = Feedback.view(entry)
    assert Enum.sort(view.mentions) == Enum.sort([bob, "keel/ext"])
    assert view.dispatch == []
  end

  test "a mention does not look at the task status", ctx do
    Repo.update_all(from(t in Task, where: t.id == ^ctx.task.id), set: [status: :verified])
    {:ok, entry} = Feedback.add(ctx.alice_scope, ctx.task.ident, %{content: "@keel/review ?"})
    assert [%{result: "queued"}] = Feedback.view(entry).dispatch
  end
end
