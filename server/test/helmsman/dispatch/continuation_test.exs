defmodule Helmsman.Dispatch.ContinuationTest do
  # add-continuation-triggers 1.3: reopen, resubmit, requested and answer
  # (decisions 3, 4, 7, 14).
  use Helmsman.DataCase, async: true

  import Helmsman.AgentsFixtures
  import Helmsman.ApiTokensFixtures
  import Helmsman.ProjectsFixtures
  import Helmsman.RunsFixtures

  alias Helmsman.{Feedback, Members, Runs, Tasks, Tx}
  alias Helmsman.Runs.{Outcome, Run, TaskGrant}
  alias Helmsman.Tasks.Task
  alias Helmsman.Workspaces.Membership

  setup do
    ctx = dispatch_fixture()
    {bob, bob_scope} = member_scope_fixture(ctx.workspace)
    {carol, carol_scope} = member_scope_fixture(ctx.workspace)

    for name <- ["keel/lead", "keel/review"],
        do: managed_agent_fixture(ctx.alice_scope, %{name: name, access: "workspace"})

    Map.merge(ctx, %{
      bob: bob,
      bob_scope: bob_scope,
      carol: carol,
      carol_scope: carol_scope,
      lead: agent_actor(ctx.workspace, "keel/lead"),
      review: agent_actor(ctx.workspace, "keel/review")
    })
  end

  ## Helpers

  defp new_task(ctx), do: task_fixture(ctx.alice_scope, ctx.project.key)

  defp set_status(task, status),
    do: Repo.update_all(from(t in Task, where: t.id == ^task.id), set: [status: status])

  # The queued runs of the task end, so a new trigger makes a new run.
  defp settle(task) do
    Tx.run(fn ->
      {:ok, Runs.cancel_pending(from(r in Run, where: r.task_id == ^task.id), :obsolete)}
    end)
  end

  defp assign(ctx, task, scope \\ nil) do
    {:ok, task} = Tasks.update(scope || ctx.alice_scope, task.ident, %{assignee: "keel/dev"})
    settle(task)
    task
  end

  defp run_scope(agent, task, attrs \\ %{}) do
    run =
      run_fixture(
        agent,
        Map.merge(
          %{
            task_id: task && task.id,
            status: :running,
            capabilities: ["read", "write_task", "create_tasks"]
          },
          attrs
        )
      )

    {scope, _token} = run_scope_fixture(run)
    {scope, run}
  end

  defp queued(task_id, agent, lane \\ :work) do
    Repo.one(
      from(r in Run,
        where:
          r.task_id == ^task_id and r.agent_id == ^agent.id and r.lane == ^lane and
            r.status == :queued
      )
    )
  end

  defp membership_id(ctx, user),
    do:
      Repo.one!(
        from(m in Membership,
          where: m.workspace_id == ^ctx.workspace.id and m.user_id == ^user.id,
          select: m.id
        )
      )

  # BOS-9: created by keel/lead in a run on bob's behalf, assigned to
  # keel/dev (without a run: bob may not trigger alice's agent).
  defp requested_task(ctx) do
    {lead_scope, _run} =
      run_scope(ctx.lead, nil, %{
        root_initiator_user_id: ctx.bob.id,
        causal_agent_ids: [ctx.lead.id]
      })

    {:ok, task} =
      Tasks.create(lead_scope, ctx.project.key, %{title: "Requested", assignee: "keel/dev"})

    set_status(task, :in_progress)
    task
  end

  ## reopen / resubmit

  describe "reopen and resubmit" do
    test "a member without the right to trigger sends the task back (scenario)", ctx do
      task = assign(ctx, new_task(ctx))
      set_status(task, :done)

      assert {:ok, detail} =
               Tasks.transition(ctx.bob_scope, task.ident, :in_progress, %{
                 feedback: %{kind: "review", content: "Missing tests"}
               })

      assert [%Outcome{agent: "keel/dev", trigger: :reopen, result: :queued, run_id: id}] =
               detail.dispatch

      run = Repo.get!(Run, id)
      assert run.lane == :work
      assert run.root_initiator_user_id == ctx.alice.id
      assert run.causal_agent_ids == [ctx.agent.id]

      assert [%{"kind" => "reopen", "from" => "done", "by_actor_id" => by} = trigger] =
               run.triggers

      assert by == ctx.bob_scope.actor.id
      assert trigger["initiator_user_id"] == ctx.alice.id
      assert trigger["feedback_id"] == hd(Feedback.for_task(Repo.reload!(task))).id
      refute Map.has_key?(trigger, "reason")
    end

    test "verified → in_progress is a reopen from verified", ctx do
      task = assign(ctx, new_task(ctx))
      set_status(task, :verified)

      assert {:ok, %{dispatch: [%Outcome{trigger: :reopen, result: :queued, run_id: id}]}} =
               Tasks.transition(ctx.alice_scope, task.ident, :in_progress)

      assert [%{"from" => "verified", "feedback_id" => nil}] = Repo.get!(Run, id).triggers
    end

    test "the source left the workspace: skipped (scenario)", ctx do
      task = assign(ctx, new_task(ctx))
      set_status(task, :done)
      {_owner, owner_scope} = member_scope_fixture(ctx.workspace, :owner)
      assert {:ok, _} = Members.remove(owner_scope, membership_id(ctx, ctx.alice))

      assert {:ok, %{dispatch: [%Outcome{result: :skipped, reason: reason}]}} =
               Tasks.transition(owner_scope, task.ident, :in_progress)

      assert reason in [:agent_disabled, :unauthorized]
      assert queued(task.id, ctx.agent) == nil
    end

    test "rejected → new without an assign grant: no_grant (scenario)", ctx do
      task = assign(ctx, new_task(ctx), ctx.bob_scope)
      assert Repo.all(from(g in TaskGrant, where: g.task_id == ^task.id)) == []
      set_status(task, :rejected)

      assert {:ok,
              %{dispatch: [%Outcome{trigger: :resubmit, result: :skipped, reason: :no_grant}]}} =
               Tasks.transition(ctx.alice_scope, task.ident, :new)

      assert queued(task.id, ctx.agent) == nil
    end

    test "resubmit inherits the assign grant", ctx do
      task = assign(ctx, new_task(ctx))
      set_status(task, :rejected)

      assert {:ok, %{dispatch: [%Outcome{trigger: :resubmit, result: :queued, run_id: id}]}} =
               Tasks.transition(ctx.bob_scope, task.ident, :new)

      assert %Run{root_initiator_user_id: root, triggers: [%{"kind" => "resubmit"}]} =
               Repo.get!(Run, id)

      assert root == ctx.alice.id
    end

    test "the agent sends its own task back: no trigger (scenario)", ctx do
      task = assign(ctx, new_task(ctx))
      set_status(task, :done)
      {scope, run} = run_scope(ctx.agent, task)

      assert {:ok, %{dispatch: []}} = Tasks.transition(scope, task.ident, :in_progress)
      assert [%Run{id: id}] = runs_of(task.id) |> Enum.filter(&(&1.status != :cancelled))
      assert id == run.id
    end
  end

  ## answer

  describe "answer" do
    test "answering an agent called in by a mention (scenario)", ctx do
      task = new_task(ctx)

      {review_scope, run} =
        run_scope(ctx.review, task, %{
          lane: :reply,
          root_initiator_user_id: ctx.bob.id,
          triggers: [trigger("mention", ctx.workspace, ctx.bob, ctx.review)]
        })

      {:ok, question} = Feedback.add(review_scope, task.ident, %{kind: "question", content: "?"})
      assert question.source_run_id == run.id

      {:ok, answer} = Feedback.add(ctx.carol_scope, task.ident, %{kind: "answer", content: "!"})

      assert [%{agent: "keel/review", trigger: "answer", result: "queued", run_id: id}] =
               Feedback.view(answer).dispatch

      new_run = Repo.get!(Run, id)
      assert new_run.lane == :reply
      assert new_run.root_initiator_user_id == ctx.bob.id

      assert [%{"kind" => "answer", "assignee_bound" => false} = trigger] = new_run.triggers
      assert trigger["by_actor_id"] == ctx.carol_scope.actor.id
      assert trigger["question_id"] == question.id
      assert trigger["feedback_id"] == answer.id
    end

    test "explicit reply selects the specified current question instead of the last one", ctx do
      task = new_task(ctx)

      {scope, original_run} =
        run_scope(ctx.review, task, %{lane: :reply, root_initiator_user_id: ctx.bob.id})

      {:ok, question} = Feedback.add(scope, task.ident, %{kind: :question, content: "First?"})
      {:ok, current} = Feedback.revise(scope, Feedback.view(question).id, %{content: "Current?"})
      {other_scope, _} = run_scope(ctx.agent, task)
      {:ok, _} = Feedback.add(other_scope, task.ident, %{kind: :question, content: "Last?"})

      {:ok, answer} =
        Feedback.add(ctx.carol_scope, task.ident, %{
          kind: :answer,
          content: "First answer",
          reply_to: Feedback.view(question).id
        })

      assert [%{agent: "keel/review", trigger: "answer", result: "queued", run_id: id}] =
               Feedback.view(answer).dispatch

      run = Repo.get!(Run, id)
      assert run.root_initiator_user_id == original_run.root_initiator_user_id
      assert run.lane == :reply
      assert hd(run.triggers)["question_id"] == current.id
    end

    test "revising an explicit answer preserves its relation without triggering again", ctx do
      task = new_task(ctx)
      {scope, _} = run_scope(ctx.review, task, %{lane: :reply})
      {:ok, question} = Feedback.add(scope, task.ident, %{kind: :question, content: "Question?"})

      {:ok, answer} =
        Feedback.add(ctx.carol_scope, task.ident, %{
          kind: :answer,
          content: "Answer",
          reply_to: Feedback.view(question).id
        })

      assert [%{trigger: "answer"}] = Feedback.view(answer).dispatch

      {:ok, revised} =
        Feedback.revise(ctx.carol_scope, Feedback.view(answer).id, %{content: "Revised answer"})

      assert revised.reply_to_seq == question.seq
      assert Feedback.view(revised).dispatch == []
    end

    test "explicit answer to a comment does not wake an unrelated question author", ctx do
      task = new_task(ctx)
      {scope, _} = run_scope(ctx.review, task, %{lane: :reply})
      {:ok, _} = Feedback.add(scope, task.ident, %{kind: :question, content: "Question?"})
      {:ok, comment} = Feedback.add(ctx.alice_scope, task.ident, %{content: "Note"})

      {:ok, answer} =
        Feedback.add(ctx.carol_scope, task.ident, %{
          kind: :answer,
          content: "Answer note",
          reply_to: Feedback.view(comment).id
        })

      assert Feedback.view(answer).dispatch == []
    end

    test "a question in an assignment run: the answer is assignee-bound", ctx do
      task = assign(ctx, new_task(ctx))
      auto_retry = %{"kind" => "retry", "retry_of" => 1, "auto" => true, "by_actor_id" => nil}

      {scope, _run} =
        run_scope(ctx.agent, task, %{
          triggers: [trigger("assign", ctx.workspace, ctx.alice, ctx.agent), auto_retry]
        })

      {:ok, _q} = Feedback.add(scope, task.ident, %{kind: "question", content: "?"})
      {:ok, answer} = Feedback.add(ctx.alice_scope, task.ident, %{kind: "answer", content: "!"})

      assert [%{trigger: "answer", result: "queued", run_id: id}] = Feedback.view(answer).dispatch
      assert [%{"assignee_bound" => true}] = Repo.get!(Run, id).triggers
      assert Repo.get!(Run, id).lane == :work
    end

    test "a question written outside a run: no_grant", ctx do
      task = new_task(ctx)
      agent_fixture(ctx.workspace, ctx.alice, "keel/ext")
      # keel/dev writing with a person's token is not a run.
      Repo.insert!(%Feedback.Entry{
        workspace_id: task.workspace_id,
        task_id: task.id,
        seq: 1,
        thread_seq: 1,
        author_id: ctx.agent.id,
        kind: :question,
        content: "?"
      })

      Repo.update_all(from(t in Task, where: t.id == ^task.id),
        set: [feedback_seq: 1, feedback_count: 1, open_question: true]
      )

      {:ok, answer} = Feedback.add(ctx.alice_scope, task.ident, %{kind: "answer", content: "!"})

      assert [%{agent: "keel/dev", trigger: "answer", result: "skipped", reason: "no_grant"}] =
               Feedback.view(answer).dispatch
    end

    test "a comment after the question: nothing (scenario)", ctx do
      task = assign(ctx, new_task(ctx))
      {scope, _run} = run_scope(ctx.agent, task)
      {:ok, _q} = Feedback.add(scope, task.ident, %{kind: "question", content: "?"})
      {:ok, comment} = Feedback.add(ctx.alice_scope, task.ident, %{content: "hmm"})
      assert Feedback.view(comment).dispatch == []
      assert queued(task.id, ctx.agent) == nil
    end

    test "a revision into an answer triggers too", ctx do
      task = assign(ctx, new_task(ctx))
      {scope, _run} = run_scope(ctx.agent, task)
      {:ok, _q} = Feedback.add(scope, task.ident, %{kind: "question", content: "?"})
      {:ok, note} = Feedback.add(ctx.alice_scope, task.ident, %{content: "draft"})
      assert Feedback.view(note).dispatch == []

      {:ok, answer} =
        Feedback.revise(ctx.alice_scope, Feedback.view(note).id, %{kind: "answer", content: "!"})

      assert [%{trigger: "answer", result: "queued"}] = Feedback.view(answer).dispatch
    end

    for status <- [:verified, :cancelled] do
      @status status
      test "work lane on a #{status} task: task_closed", ctx do
        task = assign(ctx, new_task(ctx))
        {scope, _run} = run_scope(ctx.agent, task)
        {:ok, _q} = Feedback.add(scope, task.ident, %{kind: "question", content: "?"})
        set_status(task, @status)
        {:ok, answer} = Feedback.add(ctx.alice_scope, task.ident, %{kind: "answer", content: "!"})

        assert [%{trigger: "answer", result: "skipped", reason: "task_closed"}] =
                 Feedback.view(answer).dispatch
      end
    end
  end

  ## requested

  describe "requested" do
    test "done wakes the requester to review (scenario)", ctx do
      task = requested_task(ctx)
      {dev_scope, _run} = run_scope(ctx.agent, task)

      assert {:ok, %{dispatch: [%Outcome{agent: "keel/lead", trigger: :requested, run_id: id}]}} =
               Tasks.transition(dev_scope, task.ident, :done)

      run = Repo.get!(Run, id)
      assert run.root_initiator_user_id == ctx.bob.id
      assert run.causal_agent_ids == [ctx.lead.id]
      refute ctx.agent.id in run.causal_agent_ids
      assert [%{"kind" => "requested", "event" => "done"}] = run.triggers
    end

    test "wake_on_requested off: no run, no outcome (scenario)", ctx do
      {:ok, _} = Helmsman.Agents.update(ctx.alice_scope, "keel/lead", %{wake_on_requested: false})
      task = requested_task(ctx)
      {dev_scope, _run} = run_scope(ctx.agent, task)

      assert {:ok, %{dispatch: []}} = Tasks.transition(dev_scope, task.ident, :done)
      assert queued(task.id, ctx.lead) == nil
    end

    test "the assignee asks a question (scenario)", ctx do
      task = requested_task(ctx)
      {dev_scope, _run} = run_scope(ctx.agent, task)
      {:ok, q} = Feedback.add(dev_scope, task.ident, %{kind: "question", content: "Which DB?"})

      assert [%{agent: "keel/lead", trigger: "requested", result: "queued", run_id: id}] =
               Feedback.view(q).dispatch

      assert [%{"event" => "question", "feedback_id" => fid}] = Repo.get!(Run, id).triggers
      assert fid == q.id
    end

    test "rejected wakes the requester; a person's question does not", ctx do
      task = requested_task(ctx)
      {:ok, q} = Feedback.add(ctx.alice_scope, task.ident, %{kind: "question", content: "?"})
      assert Feedback.view(q).dispatch == []

      assert {:ok, %{dispatch: [%Outcome{trigger: :requested, result: :queued, run_id: id}]}} =
               Tasks.transition(ctx.alice_scope, task.ident, :rejected)

      assert [%{"event" => "rejected"}] = Repo.get!(Run, id).triggers
    end

    test "a task created before the grant existed: no_grant", ctx do
      task = requested_task(ctx)
      Repo.delete_all(from(g in TaskGrant, where: g.task_id == ^task.id))
      {dev_scope, _run} = run_scope(ctx.agent, task)

      assert {:ok, %{dispatch: [%Outcome{result: :skipped, reason: :no_grant}]}} =
               Tasks.transition(dev_scope, task.ident, :done)
    end

    for status <- [:verified, :cancelled] do
      @status status
      test "a question on a #{status} task: task_closed", ctx do
        task = requested_task(ctx)
        set_status(task, @status)
        {dev_scope, _run} = run_scope(ctx.agent, task)
        {:ok, q} = Feedback.add(dev_scope, task.ident, %{kind: "question", content: "?"})

        assert [%{trigger: "requested", result: "skipped", reason: "task_closed"}] =
                 Feedback.view(q).dispatch
      end
    end
  end

  ## Several triggers in one write (decision 14)

  describe "one write, several triggers" do
    test "a reopen whose reason answers the requester: two runs", ctx do
      task = requested_task(ctx)
      # alice assigns it again, so keel/dev has an assign grant.
      {:ok, _} = Tasks.update(ctx.alice_scope, task.ident, %{assignee: nil})
      task = assign(ctx, task)
      set_status(task, :done)
      {lead_scope, _run} = run_scope(ctx.lead, task, %{root_initiator_user_id: ctx.bob.id})
      {:ok, _q} = Feedback.add(lead_scope, task.ident, %{kind: "question", content: "?"})

      assert {:ok, %{dispatch: dispatch}} =
               Tasks.transition(ctx.alice_scope, task.ident, :in_progress, %{
                 feedback: %{kind: "answer", content: "Yes, and fix the tests."}
               })

      assert [
               %Outcome{agent: "keel/dev", trigger: :reopen, result: :queued},
               %Outcome{agent: "keel/lead", trigger: :answer, result: :queued}
             ] = dispatch

      assert %Run{} = queued(task.id, ctx.agent)
      assert %Run{} = queued(task.id, ctx.lead)
    end

    test "done with a question: requested(done) queued, requested(question) merged", ctx do
      task = requested_task(ctx)
      {dev_scope, _run} = run_scope(ctx.agent, task)

      assert {:ok, %{dispatch: dispatch}} =
               Tasks.transition(dev_scope, task.ident, :done, %{
                 feedback: %{kind: "question", content: "Is this enough?"}
               })

      assert [
               %Outcome{agent: "keel/lead", trigger: :requested, result: :queued, run_id: id},
               %Outcome{agent: "keel/lead", trigger: :requested, result: :merged, run_id: id}
             ] = dispatch

      assert [%{"event" => "done"}, %{"event" => "question"}] = Repo.get!(Run, id).triggers

      [reason] = Feedback.for_task(Repo.reload!(task)) |> Enum.filter(&(&1.kind == :question))
      assert [%{"trigger" => "requested", "result" => "merged"}] = reason.dispatch
    end

    test "reopen and a mention of the same agent: a work run and a reply run", ctx do
      task = assign(ctx, new_task(ctx))
      set_status(task, :done)

      assert {:ok, %{dispatch: dispatch}} =
               Tasks.transition(ctx.alice_scope, task.ident, :in_progress, %{
                 feedback: %{kind: "review", content: "@keel/dev see above"}
               })

      assert [
               %Outcome{trigger: :reopen, run_id: work},
               %Outcome{trigger: :mention, run_id: reply}
             ] =
               dispatch

      assert %Run{id: ^work} = queued(task.id, ctx.agent, :work)
      assert %Run{id: ^reply} = queued(task.id, ctx.agent, :reply)
    end
  end

  ## Decision 4: who is a target

  describe "targets (decision 4)" do
    # For each trigger: the target is a managed agent (one outcome), an
    # external agent or a person (none), or caused it itself (none).
    setup ctx do
      ext = agent_fixture(ctx.workspace, ctx.alice, "keel/ext")
      Map.put(ctx, :ext, ext)
    end

    test "reopen", ctx do
      for {assignee, by, expect} <- [
            {"keel/dev", :alice, 1},
            {"keel/ext", :alice, 0},
            {:bob, :alice, 0},
            {"keel/dev", :dev, 0}
          ] do
        task = new_task(ctx)
        name = if assignee == :bob, do: ctx.bob_scope.actor.name, else: assignee
        {:ok, task} = Tasks.update(ctx.alice_scope, task.ident, %{assignee: name})
        settle(task)
        set_status(task, :done)
        scope = if by == :dev, do: elem(run_scope(ctx.agent, task), 0), else: ctx.alice_scope
        {:ok, %{dispatch: dispatch}} = Tasks.transition(scope, task.ident, :in_progress)
        assert length(dispatch) == expect, inspect({assignee, by})
      end
    end

    test "requested", ctx do
      # A person and an external agent create tasks: no grant, no target.
      for scope <- [ctx.alice_scope, external_scope(ctx)] do
        {:ok, task} = Tasks.create(scope, ctx.project.key, %{title: "T", assignee: "keel/dev"})
        settle(task)
        set_status(task, :in_progress)
        {dev_scope, _} = run_scope(ctx.agent, task)
        assert {:ok, %{dispatch: []}} = Tasks.transition(dev_scope, task.ident, :done)
      end

      # The requester moves its own task: nothing.
      task = requested_task(ctx)
      {lead_scope, _} = run_scope(ctx.lead, task)
      assert {:ok, %{dispatch: []}} = Tasks.transition(lead_scope, task.ident, :rejected)
    end

    test "answer", ctx do
      task = assign(ctx, new_task(ctx))

      # A person's or an external agent's question: nothing.
      for scope <- [ctx.bob_scope, external_scope(ctx)] do
        {:ok, _} = Feedback.add(scope, task.ident, %{kind: "question", content: "?"})
        {:ok, a} = Feedback.add(ctx.alice_scope, task.ident, %{kind: "answer", content: "!"})
        assert Feedback.view(a).dispatch == []
      end

      # The agent answers its own question: nothing.
      {scope, _} = run_scope(ctx.agent, task)
      {:ok, _} = Feedback.add(scope, task.ident, %{kind: "question", content: "?"})
      {:ok, a} = Feedback.add(scope, task.ident, %{kind: "answer", content: "never mind"})
      assert Feedback.view(a).dispatch == []
    end

    test "mention", ctx do
      task = new_task(ctx)
      bob = ctx.bob_scope.actor.name

      {:ok, f} =
        Feedback.add(ctx.alice_scope, task.ident, %{content: "@keel/dev @keel/ext @#{bob}"})

      assert [%{agent: "keel/dev", trigger: "mention"}] = Feedback.view(f).dispatch

      {scope, _} = run_scope(ctx.agent, task)
      {:ok, f} = Feedback.add(scope, task.ident, %{content: "@keel/dev note to self"})
      assert Feedback.view(f).dispatch == []
    end
  end

  ## Several refusals in one write

  # Each refused trigger chain leaves a system comment; the next one must
  # take the next feedback number (code-review-1 P2).
  describe "several refused chains in one write" do
    defp chained_scope(ctx, task) do
      run_scope(ctx.review, task, %{causal_agent_ids: [ctx.agent.id, ctx.lead.id, ctx.review.id]})
    end

    defp agent(ctx, name) do
      managed_agent_fixture(ctx.alice_scope, %{name: name, runtime_id: nil})
      agent_actor(ctx.workspace, name)
    end

    defp notes(task) do
      Repo.all(
        from(f in Feedback.Entry,
          where: f.task_id == ^task.id,
          order_by: f.seq,
          select: {f.seq, f.content}
        )
      )
    end

    test "two mentions refused: the content and both notes are saved", ctx do
      task = new_task(ctx)
      {scope, _run} = chained_scope(ctx, task)

      assert {:ok, entry} =
               Feedback.add(scope, task.ident, %{content: "@keel/dev @keel/lead please look"})

      assert [
               %{agent: "keel/dev", result: "skipped", reason: "loop_detected"},
               %{agent: "keel/lead", result: "skipped", reason: "loop_detected"}
             ] = Enum.sort_by(Feedback.view(entry).dispatch, & &1.agent)

      assert [
               {1, "@keel/dev @keel/lead" <> _},
               {2, "Did not start " <> _},
               {3, "Did not start " <> _}
             ] =
               notes(task)

      assert Repo.reload!(task).feedback_seq == 3
      assert queued(task.id, ctx.agent) == nil
      assert queued(task.id, ctx.lead) == nil
    end

    test "the transition's own trigger and its reason's both refused", ctx do
      task = assign(ctx, new_task(ctx))
      # The reopen inherits the assign grant's chain, here a full one.
      full = for name <- ~w(keel/c1 keel/c2 keel/c3 keel/c4 keel/c5), do: agent(ctx, name)

      Repo.update_all(from(g in TaskGrant, where: g.task_id == ^task.id),
        set: [causal_agent_ids: Enum.map(full, & &1.id)]
      )

      set_status(task, :done)
      {scope, _run} = chained_scope(ctx, task)

      assert {:ok, detail} =
               Tasks.transition(scope, task.ident, :in_progress, %{
                 feedback: %{kind: "review", content: "@keel/lead see the tests"}
               })

      assert [
               %Outcome{agent: "keel/dev", trigger: :reopen, reason: :chain_too_long},
               %Outcome{agent: "keel/lead", trigger: :mention, reason: :loop_detected}
             ] = detail.dispatch

      assert [
               {1, "@keel/lead" <> _},
               {2, "Did not start keel/dev" <> _},
               {3, "Did not start keel/lead" <> _}
             ] =
               notes(task)

      assert Repo.reload!(task).status == :in_progress
    end
  end

  defp external_scope(ctx) do
    %{ctx.alice_scope | actor: ctx.ext, via: :mcp}
  end
end
