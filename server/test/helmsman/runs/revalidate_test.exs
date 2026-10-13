defmodule Helmsman.Runs.RevalidateTest do
  # add-run-lifecycle 2.1: `Runs.revalidate/2` is a pure function of the
  # run and the locked rows (decision 4).
  use ExUnit.Case, async: true

  alias Helmsman.Actors.Actor
  alias Helmsman.Agents.AgentProfile
  alias Helmsman.Daemons.Runtime
  alias Helmsman.Runs
  alias Helmsman.Runs.Run
  alias Helmsman.Tasks.Task

  @alice 1
  @bob 2
  @carol 3
  @agent_id 100
  @other_agent 101

  defp trigger(kind, user, extra \\ %{}) do
    Map.merge(
      %{
        "kind" => kind,
        "by_actor_id" => 1000 + user,
        "initiator_user_id" => user,
        "causal_agent_ids" => [@agent_id],
        "at" => "2026-10-12T00:00:00Z"
      },
      extra
    )
  end

  defp run(triggers, attrs \\ %{}) do
    struct!(
      %Run{
        id: 9,
        agent_id: @agent_id,
        runtime_id: 50,
        task_id: 70,
        lane: :work,
        status: :queued,
        triggers: triggers,
        root_initiator_user_id: @alice,
        causal_agent_ids: [@agent_id]
      },
      attrs
    )
  end

  defp locked(overrides \\ %{}) do
    Map.merge(
      %{
        members: %{@alice => :owner, @bob => :member, @carol => :member},
        agent: %Actor{id: @agent_id, kind: :agent, owner_id: @alice},
        profile: %AgentProfile{actor_id: @agent_id, runtime_id: 50, access: "workspace"},
        task: %Task{id: 70, status: :new, assignee_id: @agent_id},
        runtime: %Runtime{id: 50}
      },
      overrides
    )
  end

  describe "obsolete" do
    for {name, overrides, why} <- [
          {"agent disabled",
           %{agent: %Actor{id: 100, owner_id: 1, disabled_at: ~U[2026-01-01 00:00:00Z]}},
           :agent_disabled},
          {"profile archived",
           %{profile: %AgentProfile{runtime_id: 50, archived_at: ~U[2026-01-01 00:00:00Z]}},
           :agent_archived},
          {"no profile", %{profile: nil}, :agent_archived},
          {"runtime disabled",
           %{runtime: %Runtime{id: 50, disabled_at: ~U[2026-01-01 00:00:00Z]}},
           :runtime_disabled},
          {"runtime gone", %{runtime: nil}, :runtime_disabled},
          {"agent bound elsewhere",
           %{profile: %AgentProfile{runtime_id: 51, access: "workspace"}}, :runtime_changed},
          {"task cancelled", %{task: %Task{id: 70, status: :cancelled, assignee_id: 100}},
           :task_closed},
          {"task verified", %{task: %Task{id: 70, status: :verified, assignee_id: 100}},
           :task_closed}
        ] do
      @overrides overrides
      @why why
      test name do
        assert Runs.revalidate(run([trigger("manual", @alice)]), locked(@overrides)) ==
                 {:obsolete, @why}
      end
    end

    test "a reply run on a closed task is not obsolete for that" do
      task = %Task{id: 70, status: :verified, assignee_id: @agent_id}

      assert Runs.revalidate(
               run([trigger("manual", @alice)], %{lane: :reply}),
               locked(%{task: task})
             ) ==
               :ok
    end
  end

  describe "a changed assignee" do
    setup do
      %{locked: locked(%{task: %Task{id: 70, status: :new, assignee_id: @other_agent}})}
    end

    test "makes a run of assignments only obsolete", %{locked: locked} do
      for kinds <- [["assign"], ["assign", "reopen"], ["resubmit", "unblocked"]] do
        triggers = Enum.map(kinds, &trigger(&1, @alice))
        assert Runs.revalidate(run(triggers), locked) == {:obsolete, :reassigned}
      end
    end

    test "an automatic retry marker does not count", %{locked: locked} do
      marker = %{"kind" => "retry", "retry_of" => 3, "auto" => true, "by_actor_id" => nil}

      assert Runs.revalidate(run([trigger("assign", @alice), marker]), locked) ==
               {:obsolete, :reassigned}
    end

    # add-squads decision 10: only the assignment is dropped; the run keeps
    # the trigger a person started.
    test "drops the assignment only, with a trigger a person started", %{locked: locked} do
      manual_retry = %{"kind" => "retry", "retry_of" => 3, "auto" => false, "by_actor_id" => 1001}

      assert {:pruned, %{triggers: [%{"kind" => "manual"}], root_initiator_user_id: @bob}} =
               Runs.revalidate(run([trigger("assign", @alice), trigger("manual", @bob)]), locked)

      assert {:pruned, %{triggers: [^manual_retry], root_initiator_user_id: @alice}} =
               Runs.revalidate(run([trigger("assign", @alice), manual_retry]), locked)
    end

    test "makes a run of reopen only obsolete (add-continuation-triggers)", %{locked: locked} do
      assert Runs.revalidate(run([trigger("reopen", @alice)]), locked) == {:obsolete, :reassigned}

      bound = trigger("answer", @alice, %{"assignee_bound" => true})
      marker = %{"kind" => "retry", "retry_of" => 3, "auto" => true, "by_actor_id" => nil}
      assert Runs.revalidate(run([bound, marker]), locked) == {:obsolete, :reassigned}
    end

    test "requested, mention and an unbound answer do not look at the assignee",
         %{locked: locked} do
      assert Runs.revalidate(run([trigger("requested", @alice)]), locked) == :ok

      assert Runs.revalidate(run([trigger("mention", @alice)], %{lane: :reply}), locked) == :ok

      unbound = trigger("answer", @alice, %{"assignee_bound" => false})
      assert Runs.revalidate(run([unbound]), locked) == :ok
    end

    test "is ignored without a task" do
      assert Runs.revalidate(
               run([trigger("manual", @alice)], %{task_id: nil}),
               locked(%{task: nil})
             ) ==
               :ok
    end
  end

  describe "authorization" do
    test "every source still valid" do
      assert Runs.revalidate(run([trigger("assign", @alice), trigger("manual", @bob)]), locked()) ==
               :ok
    end

    test "a merged run whose earliest source left keeps the others (scenario)" do
      run =
        run(
          [
            trigger("assign", @bob, %{"causal_agent_ids" => [7, @agent_id]}),
            trigger("manual", @alice, %{"causal_agent_ids" => [8, @agent_id]})
          ],
          %{root_initiator_user_id: @bob, causal_agent_ids: [7, 8, @agent_id]}
        )

      locked = locked(%{members: %{@alice => :owner}})

      assert {:pruned, changes} = Runs.revalidate(run, locked)
      assert changes.triggers == [Enum.at(run.triggers, 1)]
      assert changes.root_initiator_user_id == @alice
      assert changes.causal_agent_ids == [8, @agent_id]
    end

    test "a source demoted to viewer or no longer allowed by the access rule is dropped" do
      run = run([trigger("manual", @alice), trigger("manual", @bob), trigger("manual", @carol)])

      profile = %AgentProfile{
        actor_id: @agent_id,
        runtime_id: 50,
        access: "members",
        access_member_ids: [@bob]
      }

      locked =
        locked(%{
          members: %{@alice => :owner, @bob => :viewer, @carol => :member},
          profile: profile
        })

      # alice owns the agent; bob is a viewer; carol is not in the list.
      assert {:pruned, %{triggers: [kept], root_initiator_user_id: @alice}} =
               Runs.revalidate(run, locked)

      assert kept["initiator_user_id"] == @alice
    end

    test "no valid source left is unauthorized, even with a retry marker" do
      marker = %{"kind" => "retry", "retry_of" => 3, "auto" => true, "by_actor_id" => nil}
      locked = locked(%{members: %{@alice => :owner}})
      assert Runs.revalidate(run([trigger("manual", @bob), marker]), locked) == :unauthorized
    end

    test "owner_only agents: only the owner" do
      profile = %AgentProfile{actor_id: @agent_id, runtime_id: 50, access: "owner_only"}

      assert Runs.revalidate(run([trigger("manual", @bob)]), locked(%{profile: profile})) ==
               :unauthorized

      assert Runs.revalidate(run([trigger("manual", @alice)]), locked(%{profile: profile})) == :ok
    end

    test "a run without sources is checked with its root initiator" do
      assert Runs.revalidate(run([]), locked()) == :ok

      assert Runs.revalidate(run([], %{root_initiator_user_id: @bob}), locked(%{members: %{}})) ==
               :unauthorized
    end

    test "obsolete comes before unauthorized" do
      locked = locked(%{members: %{}, runtime: nil})

      assert Runs.revalidate(run([trigger("manual", @bob)]), locked) ==
               {:obsolete, :runtime_disabled}
    end
  end
end

defmodule Helmsman.Runs.RevalidateAnswerTest do
  # add-continuation-triggers 1.6: an answer run continues the run the
  # question was asked in; whether a change of assignee makes it obsolete
  # when claimed follows that run's triggers (decision 8).
  use Helmsman.DataCase, async: true

  import Helmsman.ProjectsFixtures
  import Helmsman.RunsFixtures

  alias Helmsman.{Feedback, Runs, Tasks, Tx}
  alias Helmsman.Runs.Run

  setup do
    ctx = dispatch_fixture(%{access: "workspace"})
    {carol, carol_scope} = member_scope_fixture(ctx.workspace)
    task = task_fixture(ctx.alice_scope, ctx.project.key, %{assignee: "keel/dev"})
    cancel_queued(task)
    Map.merge(ctx, %{carol: carol, carol_scope: carol_scope, task: task})
  end

  defp cancel_queued(task),
    do:
      Tx.run(fn ->
        {:ok, Runs.cancel_pending(from(r in Run, where: r.task_id == ^task.id), :obsolete)}
      end)

  defp auto_retry, do: %{"kind" => "retry", "retry_of" => 1, "auto" => true, "by_actor_id" => nil}

  # The agent asks in a run with `triggers`, alice answers, the run ends,
  # then the task goes to carol (a person) and the daemon claims.
  defp ask_answer_reassign_claim(ctx, triggers) do
    run =
      run_fixture(ctx.agent, %{
        task_id: ctx.task.id,
        status: :running,
        capabilities: ["read", "write_task"],
        triggers: triggers
      })

    {scope, _token} = run_scope_fixture(run)
    {:ok, _q} = Feedback.add(scope, ctx.task.ident, %{kind: "question", content: "?"})
    {:ok, answer} = Feedback.add(ctx.alice_scope, ctx.task.ident, %{kind: "answer", content: "!"})
    [%{trigger: "answer", result: "queued", run_id: id}] = Feedback.view(answer).dispatch

    Repo.update_all(from(r in Run, where: r.id == ^run.id),
      set: [status: :cancelled, finished_at: DateTime.utc_now()]
    )

    {:ok, _} =
      Tasks.update(ctx.alice_scope, ctx.task.ident, %{assignee: ctx.carol_scope.actor.name})

    {:ok, specs} = Runs.claim(daemon_ctx(daemon_of(ctx.agent)), "http://localhost")
    {Repo.get!(Run, id), specs}
  end

  test "[assign, auto retry]: the answer run is obsolete after a reassignment (scenario)", ctx do
    triggers = [trigger("assign", ctx.workspace, ctx.alice, ctx.agent), auto_retry()]

    assert {%Run{status: :cancelled, failure_reason: :obsolete}, []} =
             ask_answer_reassign_claim(ctx, triggers)
  end

  test "[answer(true), auto retry] asking again: obsolete too", ctx do
    answer = trigger("answer", ctx.workspace, ctx.alice, ctx.agent, %{"assignee_bound" => true})

    assert {%Run{status: :cancelled, failure_reason: :obsolete}, []} =
             ask_answer_reassign_claim(ctx, [answer, auto_retry()])
  end

  test "assigned by reopen only: obsolete after a reassignment", ctx do
    assert {%Run{status: :cancelled}, []} =
             ask_answer_reassign_claim(ctx, [
               trigger("reopen", ctx.workspace, ctx.alice, ctx.agent)
             ])
  end

  for {name, kinds} <- [
        {"[manual] (scenario)", ["manual"]},
        {"[assign, manual retry]", ["assign", :manual_retry]}
      ] do
    @kinds kinds
    test "#{name}: the answer run is still claimed", ctx do
      triggers =
        Enum.map(@kinds, fn
          :manual_retry ->
            %{
              "kind" => "retry",
              "retry_of" => 1,
              "auto" => false,
              "by_actor_id" => ctx.carol_scope.actor.id
            }

          kind ->
            trigger(kind, ctx.workspace, ctx.carol, ctx.agent)
        end)

      assert {%Run{status: :claimed, id: id}, [spec]} = ask_answer_reassign_claim(ctx, triggers)
      assert spec.run_id == id
    end
  end
end
