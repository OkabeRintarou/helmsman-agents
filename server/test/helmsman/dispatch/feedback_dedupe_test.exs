defmodule Helmsman.Dispatch.FeedbackDedupeTest do
  # add-nested-feedback-replies 1.1 (decision 12): run-dispatch「同一条 Feedback
  # 对同一目标只触发一次」— per target, answer > requested > mention, each
  # with its own checks; a queued or merged one covers the target's other
  # mentions.
  use Helmsman.DataCase, async: true

  import Helmsman.AgentsFixtures
  import Helmsman.DependencyFixtures, only: [put_status!: 2]
  import Helmsman.ProjectsFixtures
  import Helmsman.RunLifecycleFixtures, only: [running_run!: 2]
  import Helmsman.RunsFixtures

  alias Helmsman.Dispatch.Continuation
  alias Helmsman.Events
  alias Helmsman.Feedback
  alias Helmsman.Feedback.Entry
  alias Helmsman.Members
  alias Helmsman.Runs.{Outcome, Run, RunSteer}
  alias Helmsman.Tasks
  alias Helmsman.Tasks.Task
  alias Helmsman.Workspaces.Membership

  setup do
    ctx = dispatch_fixture()
    {bob, bob_scope} = member_scope_fixture(ctx.workspace)
    {carol, carol_scope} = member_scope_fixture(ctx.workspace)

    for name <- ["keel/lead", "keel/review", "keel/qa"],
        do: managed_agent_fixture(ctx.alice_scope, %{name: name, access: "workspace"})

    Map.merge(ctx, %{
      bob: bob,
      bob_scope: bob_scope,
      carol: carol,
      carol_scope: carol_scope,
      lead: agent_actor(ctx.workspace, "keel/lead"),
      review: agent_actor(ctx.workspace, "keel/review"),
      qa: agent_actor(ctx.workspace, "keel/qa")
    })
  end

  ## Helpers

  defp new_task(ctx), do: task_fixture(ctx.alice_scope, ctx.project.key)

  defp run_scope(agent, task, attrs) do
    run =
      run_fixture(
        agent,
        Map.merge(
          %{task_id: task && task.id, status: :running, capabilities: ["read", "write_task"]},
          attrs
        )
      )

    {scope, _token} = run_scope_fixture(run)
    {scope, run}
  end

  # A question of `agent` asked in a reply-lane run started by `initiator`.
  defp question!(ctx, agent, task, initiator \\ nil) do
    initiator = initiator || ctx.alice

    {scope, run} =
      run_scope(agent, task, %{
        lane: :reply,
        root_initiator_user_id: initiator.id,
        causal_agent_ids: [agent.id],
        triggers: [trigger("mention", ctx.workspace, initiator, agent)]
      })

    {:ok, q} = Feedback.add(scope, task.ident, %{kind: "question", content: "方案 A 还是 B？"})
    {q, run}
  end

  # A question of keel/dev written outside a run: an answer has no grant.
  defp orphan_question!(task, author) do
    Repo.insert!(%Entry{
      workspace_id: task.workspace_id,
      task_id: task.id,
      seq: 1,
      thread_seq: 1,
      author_id: author.id,
      kind: :question,
      content: "?"
    })

    Repo.update_all(from(t in Task, where: t.id == ^task.id),
      set: [feedback_seq: 1, feedback_count: 1, open_question: true]
    )
  end

  defp answer!(scope, task, content, attrs \\ %{}) do
    {:ok, entry} =
      Feedback.add(scope, task.ident, Map.merge(%{kind: "answer", content: content}, attrs))

    {entry, Feedback.view(entry).dispatch}
  end

  # The task's runs of `agent` other than `except`.
  defp runs(task, agent, except \\ nil) do
    Repo.all(
      from(r in Run,
        where:
          r.task_id == ^task.id and r.agent_id == ^agent.id and
            r.id != ^((except && except.id) || 0),
        order_by: r.id
      )
    )
  end

  defp shape(dispatch),
    do: Enum.map(dispatch, &{&1.agent, &1.trigger, &1.result, &1.reason})

  ## Scenarios

  describe "回答与提及同一目标" do
    test "回答里又 @了提问的 Agent: one run, by answer; the mention covered", ctx do
      task = new_task(ctx)
      {_q, qrun} = question!(ctx, ctx.review, task, ctx.bob)

      {_answer, dispatch} = answer!(ctx.alice_scope, task, "@keel/review 用方案 B")

      assert shape(dispatch) == [
               {"keel/review", "answer", "queued", nil},
               {"keel/review", "mention", "skipped", "covered"}
             ]

      assert [run] = runs(task, ctx.review, qrun)
      assert [%{"kind" => "answer"}] = run.triggers
      # The answer's own authority: the question run's.
      assert run.lane == :reply
      assert run.root_initiator_user_id == ctx.bob.id
      assert run.causal_agent_ids == qrun.causal_agent_ids
    end

    test "回答没有排上队，提及照常派发 (no_grant): the mention on alice's authority", ctx do
      task = new_task(ctx)
      orphan_question!(task, ctx.agent)

      {_answer, dispatch} = answer!(ctx.alice_scope, task, "@keel/dev 用方案 B")

      assert [
               {"keel/dev", "answer", "skipped", "no_grant"},
               {"keel/dev", "mention", result, nil}
             ] = shape(dispatch)

      assert result in ["queued", "merged"]
      assert [run] = runs(task, ctx.agent)
      assert run.lane == :reply and run.root_initiator_user_id == ctx.alice.id
      assert [%{"kind" => "mention"}] = run.triggers
    end

    test "继承的授权失效: the answer is refused, the mention judged on its own", ctx do
      task = new_task(ctx)
      {_q, qrun} = question!(ctx, ctx.review, task, ctx.bob)
      membership = Repo.get_by!(Membership, workspace_id: ctx.workspace.id, user_id: ctx.bob.id)
      {:ok, _} = Members.remove(ctx.alice_scope, membership.id)

      {_answer, dispatch} = answer!(ctx.alice_scope, task, "@keel/review 用方案 B")

      assert [
               {"keel/review", "answer", "skipped", reason},
               {"keel/review", "mention", "queued", nil}
             ] =
               shape(dispatch)

      assert reason != "covered"
      assert [run] = runs(task, ctx.review, qrun)
      assert run.root_initiator_user_id == ctx.alice.id and run.lane == :reply
    end

    test "所有候选都不能派发: each its reason, no run, nothing covered", ctx do
      task = new_task(ctx)
      orphan_question!(task, ctx.agent)

      {_answer, dispatch} = answer!(ctx.carol_scope, task, "@keel/dev 用方案 B")

      assert shape(dispatch) == [
               {"keel/dev", "answer", "skipped", "no_grant"},
               {"keel/dev", "mention", "skipped", "unauthorized"}
             ]

      assert runs(task, ctx.agent) == []
    end

    test "回答被依赖延后: deferred does not cover; only queued and merged do" do
      outcome = &%Outcome{agent: "keel/dev", trigger: :answer, result: &1}
      refute Continuation.covers?(outcome.(:deferred))
      refute Continuation.covers?(%{outcome.(:skipped) | reason: :no_grant})
      refute Continuation.covers?(nil)
      assert Continuation.covers?(outcome.(:queued))
      assert Continuation.covers?(outcome.(:merged))
    end

    # An answer is not an assignment trigger: merged into the assignment's
    # deferred run it starts the run (merged), and that covers the mention.
    test "an answer merged into a deferred assignment run covers the mention", ctx do
      prereq = new_task(ctx)

      {:ok, task} =
        Tasks.create(ctx.alice_scope, ctx.project.key, %{
          title: "Blocked",
          assignee: "keel/dev",
          depends_on: [prereq.ident]
        })

      assert [%Run{status: :deferred} = deferred] = runs(task, ctx.agent)

      {scope, _qrun} =
        run_scope(ctx.agent, task, %{
          root_initiator_user_id: ctx.alice.id,
          causal_agent_ids: [ctx.agent.id],
          triggers: [trigger("assign", ctx.workspace, ctx.alice, ctx.agent)]
        })

      {:ok, _q} = Feedback.add(scope, task.ident, %{kind: "question", content: "?"})
      {_answer, dispatch} = answer!(ctx.alice_scope, task, "@keel/dev 用方案 B")

      assert shape(dispatch) == [
               {"keel/dev", "answer", "merged", nil},
               {"keel/dev", "mention", "skipped", "covered"}
             ]

      assert Repo.get!(Run, deferred.id).status == :queued
    end

    test "提及两个 Agent: keel/review only by answer, keel/qa by mention", ctx do
      task = new_task(ctx)
      {_q, qrun} = question!(ctx, ctx.review, task)

      {_answer, dispatch} = answer!(ctx.alice_scope, task, "@keel/review @keel/qa 用方案 B")

      assert shape(dispatch) == [
               {"keel/review", "answer", "queued", nil},
               {"keel/review", "mention", "skipped", "covered"},
               {"keel/qa", "mention", "queued", nil}
             ]

      assert [_] = runs(task, ctx.review, qrun)
      assert [%Run{triggers: [%{"kind" => "mention"}]}] = runs(task, ctx.qa)
    end
  end

  describe "修订已回答的回答" do
    test "保留原有提及: nothing new", ctx do
      task = new_task(ctx)
      {q, _qrun} = question!(ctx, ctx.review, task)

      {answer, _} =
        answer!(ctx.alice_scope, task, "@keel/review 用方案 B", %{reply_to: Feedback.view(q).id})

      before = Repo.aggregate(Run, :count)

      {:ok, revised} =
        Feedback.revise(ctx.alice_scope, Feedback.view(answer).id, %{
          content: "@keel/review 用方案 C"
        })

      assert Feedback.view(revised).dispatch == []
      assert Repo.aggregate(Run, :count) == before
    end

    test "新增提及: one mention on alice's authority; unauthorized for carol", ctx do
      task = new_task(ctx)
      {q, _qrun} = question!(ctx, ctx.review, task)
      {answer, _} = answer!(ctx.alice_scope, task, "用方案 B", %{reply_to: Feedback.view(q).id})

      {:ok, revised} =
        Feedback.revise(ctx.alice_scope, Feedback.view(answer).id, %{
          content: "@keel/review 用方案 B"
        })

      assert [{"keel/review", "mention", result, nil}] = shape(Feedback.view(revised).dispatch)
      assert result in ["queued", "merged"]

      # carol may not trigger keel/dev (alice's owner_only agent).
      task2 = new_task(ctx)
      orphan_question!(task2, ctx.agent)
      {answer2, _} = answer!(ctx.carol_scope, task2, "用方案 B")

      {:ok, revised2} =
        Feedback.revise(ctx.carol_scope, Feedback.view(answer2).id, %{content: "@keel/dev 用方案 B"})

      assert shape(Feedback.view(revised2).dispatch) == [
               {"keel/dev", "mention", "skipped", "unauthorized"}
             ]
    end
  end

  describe "回调提出方与提及" do
    # BOS-n created by keel/lead in a run on alice's behalf, assigned to keel/dev.
    defp requested_task(ctx) do
      {lead_scope, _run} =
        run_scope(ctx.lead, nil, %{
          root_initiator_user_id: ctx.alice.id,
          causal_agent_ids: [ctx.lead.id],
          capabilities: ["read", "write_task", "create_tasks"]
        })

      {:ok, task} =
        Tasks.create(lead_scope, ctx.project.key, %{
          title: "Requested",
          assignee: "keel/dev",
          start: false
        })

      put_status!(task, :in_progress)
      task
    end

    defp dev_question!(ctx, task) do
      {dev_scope, _run} =
        run_scope(ctx.agent, task, %{
          root_initiator_user_id: ctx.alice.id,
          causal_agent_ids: [ctx.agent.id]
        })

      {:ok, q} =
        Feedback.add(dev_scope, task.ident, %{kind: "question", content: "@keel/lead 用哪个库？"})

      Feedback.view(q).dispatch
    end

    test "the callback queued covers the mention of the requester", ctx do
      task = requested_task(ctx)

      assert shape(dev_question!(ctx, task)) == [
               {"keel/lead", "requested", "queued", nil},
               {"keel/lead", "mention", "skipped", "covered"}
             ]

      assert [_] = runs(task, ctx.lead)
    end

    test "wake_on_requested off: no callback, the mention runs", ctx do
      {:ok, _} = Helmsman.Agents.update(ctx.alice_scope, "keel/lead", %{wake_on_requested: false})
      task = requested_task(ctx)

      assert [{"keel/lead", "mention", result, nil}] = shape(dev_question!(ctx, task))
      assert result in ["queued", "merged"]
    end
  end

  describe "targets are identities" do
    test "@小队 S and answering S's leader: two targets, each triggered" do
      ctx = Helmsman.SquadsFixtures.squads_fixture()
      task = task_fixture(ctx.alice_scope, ctx.project.key)
      {_q, _qrun} = question!(ctx, ctx.lead, task)

      {_answer, dispatch} = answer!(ctx.alice_scope, task, "@web-team 用方案 B")

      assert [
               %{agent: "keel/lead", trigger: "answer", result: "queued"},
               %{trigger: "mention", squad: "web-team", result: mention}
             ] = dispatch

      assert mention in ["queued", "merged"]
      refute Enum.any?(dispatch, &(&1.reason == "covered"))
    end
  end

  describe "插话" do
    setup ctx do
      task = new_task(ctx)

      run =
        running_run!(ctx.agent, %{
          task_id: task.id,
          root_initiator_user_id: ctx.alice.id,
          capabilities: ["read", "write_task"]
        })

      :ok = Events.subscribe(Events.topic(:daemon, run.daemon_id))
      Map.merge(ctx, %{task: task, run: run})
    end

    test "the answer queued carries the mark, pushed once; the mention covered, unmarked", ctx do
      {scope, _} = run_scope_fixture(ctx.run)
      {:ok, _q} = Feedback.add(scope, ctx.task.ident, %{kind: "question", content: "?"})

      {_answer, dispatch} =
        answer!(ctx.alice_scope, ctx.task, "@keel/dev 用方案 B", %{steer_run_id: ctx.run.id})

      assert [answer, mention] = dispatch

      assert {answer.trigger, answer.result, answer.steer_run_id} ==
               {"answer", "queued", ctx.run.id}

      assert {mention.trigger, mention.reason, mention.steer_run_id} ==
               {"mention", "covered", nil}

      assert [%RunSteer{}] = Repo.all(RunSteer)
      assert_receive {:steer_run, _, _, _}
      refute_receive {:steer_run, _, _, _}, 50
      refute Enum.any?(dispatch, &(&1.trigger == "steer"))
    end

    test "the answer skipped, the mention queued carries the mark, pushed once", ctx do
      orphan_question!(ctx.task, ctx.agent)

      {_answer, dispatch} =
        answer!(ctx.alice_scope, ctx.task, "@keel/dev 用方案 B", %{steer_run_id: ctx.run.id})

      assert [answer, mention] = dispatch
      assert {answer.reason, mention.trigger, mention.result} == {"no_grant", "mention", "queued"}
      assert mention.steer_run_id == ctx.run.id
      assert [%RunSteer{}] = Repo.all(RunSteer)
      assert_receive {:steer_run, _, _, _}
      refute_receive {:steer_run, _, _, _}, 50
      refute Enum.any?(dispatch, &(&1.trigger == "steer"))
    end
  end
end

defmodule HelmsmanWeb.FeedbackDedupeInterfacesTest do
  # The first scenario of 「同一条 Feedback 对同一目标只触发一次」 through MCP
  # `add_feedback` and REST: the same outcomes as the domain call.
  use HelmsmanWeb.ConnCase, async: true

  import Helmsman.AgentsFixtures
  import Helmsman.ApiTokensFixtures
  import Helmsman.ProjectsFixtures
  import Helmsman.RunsFixtures
  import HelmsmanMCP.ToolHelpers
  import HelmsmanWeb.APIHelpers

  alias Helmsman.Feedback

  setup do
    ctx = dispatch_fixture()
    managed_agent_fixture(ctx.alice_scope, %{name: "keel/review", access: "workspace"})
    Map.put(ctx, :review, agent_actor(ctx.workspace, "keel/review"))
  end

  defp question!(ctx) do
    task = task_fixture(ctx.alice_scope, ctx.project.key)

    run =
      run_fixture(ctx.review, %{
        task_id: task.id,
        status: :running,
        lane: :reply,
        root_initiator_user_id: ctx.alice.id,
        capabilities: ["read", "write_task"]
      })

    {scope, _} = run_scope_fixture(run)
    {:ok, _} = Feedback.add(scope, task.ident, %{kind: "question", content: "?"})
    task
  end

  @expected [
    %{"agent" => "keel/review", "trigger" => "answer", "result" => "queued", "reason" => nil},
    %{
      "agent" => "keel/review",
      "trigger" => "mention",
      "result" => "skipped",
      "reason" => "covered"
    }
  ]

  test "MCP add_feedback", ctx do
    task = question!(ctx)
    session = mcp_session(ctx.alice, ctx.workspace)

    result =
      call!(session, "add_feedback", %{
        "task_id" => task.ident,
        "kind" => "answer",
        "content" => "@keel/review 用方案 B"
      })

    assert result["dispatch"] == @expected
  end

  test "REST POST feedback", ctx do
    task = question!(ctx)
    %{token: token} = api_token_fixture(ctx.alice_scope)

    data =
      :post
      |> api_send(token, w(ctx.workspace.slug, "/tasks/#{task.ident}/feedback"), %{
        kind: "answer",
        content: "@keel/review 用方案 B"
      })
      |> body!(201)

    assert Enum.map(data["data"]["dispatch"], &Map.take(&1, ~w(agent trigger result reason))) ==
             @expected
  end
end
