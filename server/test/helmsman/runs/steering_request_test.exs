defmodule Helmsman.Runs.SteeringRequestTest do
  # add-run-steering 1.2: the steering request on Feedback.add/3
  # (decisions 3, 5) — run-steering「插话请求」「插话的权限」「兜底触发」
  # 「实时送达」.
  use Helmsman.DataCase, async: true

  import Helmsman.ApiTokensFixtures, only: [agent_fixture: 3]
  import Helmsman.AgentsFixtures
  import Helmsman.ProjectsFixtures
  import Helmsman.RunLifecycleFixtures, only: [running_run!: 2, finish!: 4]
  import Helmsman.RunsFixtures

  alias Helmsman.Daemons.Runtime
  alias Helmsman.{Events, Feedback, Runs, Tasks, Tx}
  alias Helmsman.Feedback.Entry
  alias Helmsman.Runs.{Run, RunSteer, Triggers}

  setup do
    ctx = dispatch_fixture()
    {bob, bob_scope} = member_scope_fixture(ctx.workspace)
    task = task_fixture(ctx.alice_scope, ctx.project.key)
    run = running_run!(ctx.agent, %{task_id: task.id})
    :ok = Events.subscribe(Events.topic(:daemon, run.daemon_id))
    Map.merge(ctx, %{bob: bob, bob_scope: bob_scope, task: task, run: run})
  end

  defp add(scope, task, attrs), do: Feedback.add(scope, task.ident, attrs)

  defp steer(ctx, attrs \\ %{}) do
    add(
      ctx.alice_scope,
      ctx.task,
      Map.merge(%{content: "Use another approach", steer_run_id: ctx.run.id}, attrs)
    )
  end

  defp pending(task_id, agent_id) do
    Repo.all(
      from(r in Run,
        where:
          r.task_id == ^task_id and r.agent_id == ^agent_id and
            r.status in ^Run.pending_statuses(),
        order_by: r.id
      )
    )
  end

  defp steers, do: Repo.all(RunSteer)

  defp entries(task), do: Repo.aggregate(from(f in Entry, where: f.task_id == ^task.id), :count)

  defp errors(changeset), do: errors_on(changeset)[:steer_run_id]

  describe "插话请求" do
    test "an agent cannot steer (scenario)", ctx do
      ext = agent_fixture(ctx.workspace, ctx.alice, "alice/cli")
      scope = %{ctx.alice_scope | actor: ext, via: :mcp}

      assert {:error, changeset} =
               add(scope, ctx.task, %{content: "hi", steer_run_id: ctx.run.id})

      assert errors(changeset) == ["only people can send feedback to a running agent"]
      assert entries(ctx.task) == 0
    end

    test "a run of another task (scenario)", ctx do
      other = task_fixture(ctx.alice_scope, ctx.project.key)
      other_run = run_fixture(ctx.agent, %{task_id: other.id, status: :queued})

      assert {:error, changeset} =
               add(ctx.alice_scope, ctx.task, %{content: "hi", steer_run_id: other_run.id})

      assert errors(changeset) == ["is not a run of #{ctx.task.ident}"]
      assert entries(ctx.task) == 0
      assert steers() == []
    end

    test "a run of another workspace or none is not a run of the task", ctx do
      other = dispatch_fixture()
      task = task_fixture(other.alice_scope, other.project.key)
      foreign = run_fixture(other.agent, %{task_id: task.id})

      for id <- [foreign.id, foreign.id + 1_000_000] do
        assert {:error, changeset} =
                 add(ctx.alice_scope, ctx.task, %{content: "hi", steer_run_id: id})

        assert errors(changeset) == ["is not a run of #{ctx.task.ident}"]
      end
    end

    test "steer_run_id must be a positive integer; a decimal string is fine", ctx do
      for bad <- [0, -1, "x", "1.5", 1.0] do
        assert {:error, changeset} =
                 add(ctx.alice_scope, ctx.task, %{content: "hi", steer_run_id: bad})

        assert errors(changeset) == ["must be a positive integer"]
      end

      assert {:ok, _entry} =
               add(ctx.alice_scope, ctx.task, %{
                 "content" => "hi",
                 "steer_run_id" => to_string(ctx.run.id)
               })

      assert [%RunSteer{}] = steers()
    end

    test "revise/3 and transition reasons refuse steer_run_id", ctx do
      {:ok, entry} = add(ctx.alice_scope, ctx.task, %{content: "first"})
      id = Feedback.view(entry).id

      assert {:error, changeset} =
               Feedback.revise(ctx.alice_scope, id, %{content: "again", steer_run_id: ctx.run.id})

      assert errors(changeset) == ["can only be given with new feedback"]

      assert {:error, changeset} =
               Tasks.transition(ctx.alice_scope, ctx.task.ident, :cancelled, %{
                 feedback: %{content: "stop", steer_run_id: ctx.run.id}
               })

      assert errors(changeset) == ["can only be given with new feedback"]
      assert steers() == []
    end
  end

  describe "插话的权限" do
    test "a person who may not trigger the agent (scenario)", ctx do
      assert {:ok, entry} =
               add(ctx.bob_scope, ctx.task, %{content: "Try this", steer_run_id: ctx.run.id})

      assert [
               %{agent: "keel/dev", trigger: "steer", result: "skipped", reason: "unauthorized"} =
                 item
             ] =
               Feedback.view(entry).dispatch

      assert item.steer_run_id == ctx.run.id
      assert Feedback.view(entry).steer == nil
      assert pending(ctx.task.id, ctx.agent.id) == []
      assert steers() == []
      refute_receive {:steer_run, _, _, _}
    end

    test "other agents' triggers are not affected", ctx do
      managed_agent_fixture(ctx.alice_scope, %{name: "keel/other", access: "workspace"})
      other = agent_actor(ctx.workspace, "keel/other")

      assert {:ok, entry} =
               add(ctx.bob_scope, ctx.task, %{
                 content: "@keel/other look",
                 steer_run_id: ctx.run.id
               })

      assert [
               %{agent: "keel/other", trigger: "mention", result: "queued", steer_run_id: nil},
               %{agent: "keel/dev", trigger: "steer", result: "skipped"}
             ] = Feedback.view(entry).dispatch

      assert [%Run{triggers: [trigger]}] = pending(ctx.task.id, other.id)
      refute Map.has_key?(trigger, "steer_run_id")
    end
  end

  describe "兜底触发" do
    test "a plain comment steers (scenario)", ctx do
      assert {:ok, entry} = steer(ctx)

      assert [%{agent: "keel/dev", trigger: "steer", result: "queued", run_id: run_id} = item] =
               Feedback.view(entry).dispatch

      assert item.steer_run_id == ctx.run.id
      assert [%Run{id: ^run_id, lane: :work} = fallback] = pending(ctx.task.id, ctx.agent.id)
      alice_actor = human_actor(ctx.workspace, ctx.alice)

      assert [
               %{
                 "kind" => "steer",
                 "by_actor_id" => by,
                 "initiator_user_id" => initiator,
                 "causal_agent_ids" => causal,
                 "instructions" => nil,
                 "feedback_id" => feedback_id,
                 "steer_run_id" => steer_run_id
               }
             ] = fallback.triggers

      assert {by, initiator, causal} == {alice_actor.id, ctx.alice.id, [ctx.agent.id]}
      assert {feedback_id, steer_run_id} == {entry.id, ctx.run.id}
      assert fallback.root_initiator_user_id == ctx.alice.id
      refute Triggers.run_bound(fallback)
    end

    test "steering and @ the same agent: one mention, no steer (scenario)", ctx do
      assert {:ok, entry} = steer(ctx, %{content: "@keel/dev change the approach"})

      assert [%{agent: "keel/dev", trigger: "mention", result: "queued"} = item] =
               Feedback.view(entry).dispatch

      assert item.steer_run_id == ctx.run.id
      assert [%Run{lane: :reply, triggers: [trigger]}] = pending(ctx.task.id, ctx.agent.id)
      assert %{"kind" => "mention", "steer_run_id" => id} = trigger
      assert id == ctx.run.id
      assert [%RunSteer{}] = steers()
    end

    test "a reply-lane run steered: the fallback is in the reply lane", ctx do
      Repo.update_all(from(r in Run, where: r.id == ^ctx.run.id), set: [lane: :reply])

      assert {:ok, entry} = steer(ctx)
      assert [%{trigger: "steer", result: "queued"}] = Feedback.view(entry).dispatch
      assert [%Run{lane: :reply}] = pending(ctx.task.id, ctx.agent.id)
    end

    test "the fallback merges into a queued run of the agent", ctx do
      queued = run_fixture(ctx.agent, %{task_id: ctx.task.id, status: :queued})

      assert {:ok, entry} = steer(ctx)
      assert [%{trigger: "steer", result: "merged", run_id: id}] = Feedback.view(entry).dispatch
      assert id == queued.id
      assert [%RunSteer{}] = steers()
      assert_receive {:steer_run, _, _, _}
    end

    test "over the rate limit (scenario): skipped, no push, no steering state", ctx do
      for _ <- 1..19, do: run_fixture(ctx.agent, %{task_id: ctx.task.id, status: :cancelled})

      assert {:ok, entry} = steer(ctx)

      assert [%{agent: "keel/dev", trigger: "steer", result: "skipped", reason: "rate_limited"}] =
               Feedback.view(entry).dispatch

      assert Feedback.view(entry).steer == nil
      assert steers() == []
      refute_receive {:steer_run, _, _, _}
      assert {:ok, %{run_id: run_id}} = Runs.steerable(ctx.alice_scope, ctx.task.ident)
      assert run_id == ctx.run.id
    end

    for status <- [:succeeded, :failed] do
      test "refused fallback: run #{status} afterwards creates no run for the record", ctx do
        for _ <- 1..19, do: run_fixture(ctx.agent, %{task_id: ctx.task.id, status: :cancelled})
        assert {:ok, entry} = steer(ctx)
        assert [%{trigger: "steer", reason: "rate_limited"}] = Feedback.view(entry).dispatch

        finish!(ctx.agent, ctx.run.id, unquote(status), %{
          failure_reason: unquote(if status == :failed, do: :cli_error)
        })

        assert pending(ctx.task.id, ctx.agent.id) == []
        refute_receive {:steer_run, _, _, _}
      end
    end

    test "with @ over the rate limit: two items, no push, no row", ctx do
      for _ <- 1..19, do: run_fixture(ctx.agent, %{task_id: ctx.task.id, status: :cancelled})

      assert {:ok, entry} = steer(ctx, %{content: "@keel/dev please"})

      assert [
               %{trigger: "mention", result: "skipped", reason: "rate_limited"},
               %{trigger: "steer", result: "skipped", reason: "rate_limited"}
             ] = Feedback.view(entry).dispatch

      assert steers() == []
      refute_receive {:steer_run, _, _, _}
    end
  end

  describe "实时送达" do
    test "running (scenario): pushed after the commit", ctx do
      assert {:ok, entry} = steer(ctx)
      %{id: feedback_ident} = Feedback.view(entry)
      run_id = ctx.run.id
      entry_id = entry.id

      assert_receive {:steer_run, ^run_id, ^entry_id, text}
      assert text =~ feedback_ident
      assert text =~ "> Use another approach"

      assert [%RunSteer{run_id: ^run_id, feedback_id: ^entry_id, acked_at: nil}] = steers()

      assert %{run_id: ^run_id, agent: "keel/dev", sent_at: %DateTime{}, acked_at: nil} =
               Feedback.view(entry).steer
    end

    test "claimed (scenario): no push; the fallback is queued", ctx do
      Repo.update_all(from(r in Run, where: r.id == ^ctx.run.id), set: [status: :claimed])

      assert {:ok, entry} = steer(ctx)
      assert [%{trigger: "steer", result: "queued"}] = Feedback.view(entry).dispatch
      assert steers() == []
      refute_receive {:steer_run, _, _, _}
    end

    test "cancelling or ended: no row, no push", ctx do
      for status <- [:cancelling, :succeeded, :failed] do
        Repo.update_all(from(r in Run, where: r.id == ^ctx.run.id), set: [status: status])
        assert {:ok, _entry} = steer(ctx)
        assert steers() == []
        refute_receive {:steer_run, _, _, _}
      end
    end

    test "runtime disabled (scenario): skipped, no push", ctx do
      runtime_id = profile(ctx.agent).runtime_id

      Repo.update_all(from(r in Runtime, where: r.id == ^runtime_id),
        set: [disabled_at: DateTime.utc_now()]
      )

      assert {:ok, entry} = steer(ctx)

      assert [
               %{
                 agent: "keel/dev",
                 trigger: "steer",
                 result: "skipped",
                 reason: "runtime_disabled"
               }
             ] =
               Feedback.view(entry).dispatch

      assert Feedback.view(entry).steer == nil
      assert steers() == []
      refute_receive {:steer_run, _, _, _}
    end

    test "no push when the transaction rolls back", ctx do
      assert_raise RuntimeError, "boom", fn ->
        Tx.run(fn ->
          {:ok, _entry} = steer(ctx)
          raise "boom"
        end)
      end

      refute_receive {:steer_run, _, _, _}
      assert steers() == []
    end
  end
end
