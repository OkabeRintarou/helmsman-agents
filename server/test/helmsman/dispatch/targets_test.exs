defmodule Helmsman.Dispatch.TargetsTest do
  # add-continuation-triggers 1.2: the trigger targets are locked before
  # the task row, with savepoint retries (decision 6). The concurrent
  # tests commit on connections of their own.
  use ExUnit.Case, async: false

  import Ecto.Query
  import Helmsman.AgentsFixtures
  import Helmsman.ApiTokensFixtures
  import Helmsman.ProjectsFixtures
  import Helmsman.RunsFixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias Helmsman.{Agents, CommittedData, Feedback, Repo, Tasks, Tx}
  alias Helmsman.Dispatch.Targets
  alias Helmsman.Feedback.Entry
  alias Helmsman.Runs.{Outcome, Run, TaskGrant}
  alias Helmsman.Tasks.Task, as: TaskRow
  alias Helmsman.Tasks.TaskEvent

  @moduletag timeout: 60_000

  defp committed_ctx do
    ctx =
      CommittedData.unboxed(fn ->
        ctx = dispatch_fixture()
        {bob, bob_scope} = member_scope_fixture(ctx.workspace)

        for name <- ~w(keel/qa keel/a1 keel/a2 keel/a3 keel/review),
            do: managed_agent_fixture(ctx.alice_scope, %{name: name, access: "workspace"})

        task = task_fixture(ctx.alice_scope, ctx.project.key, %{assignee: "keel/dev"})
        Repo.update_all(from(r in Run, where: r.task_id == ^task.id), set: [status: :cancelled])
        Repo.update_all(from(t in TaskRow, where: t.id == ^task.id), set: [status: :done])
        Map.merge(ctx, %{bob: bob, bob_scope: bob_scope, task: Repo.reload!(task)})
      end)

    on_exit(fn -> CommittedData.delete_user_data!([ctx.alice.id, ctx.bob.id]) end)
    ctx
  end

  # Reassigns the task on a connection of its own and commits. Directly:
  # `Tasks.update/4` with an assignee waits for the transition's graph
  # lock since `add-dependency-dispatch` (decision 4), so only a writer
  # outside it can still interleave here; the retry is kept for that.
  defp reassign!(ctx, name) do
    Task.async(fn ->
      CommittedData.unboxed(fn ->
        agent = agent_actor(ctx.workspace, name)

        Repo.update_all(from(t in TaskRow, where: t.id == ^ctx.task.id),
          set: [assignee_id: agent.id]
        )

        # The grant `Helmsman.Dispatch.on_assignee_change/4` would record.
        Repo.delete_all(from(g in TaskGrant, where: g.task_id == ^ctx.task.id))

        Repo.insert!(%TaskGrant{
          workspace_id: ctx.task.workspace_id,
          task_id: ctx.task.id,
          agent_id: agent.id,
          kind: :assign,
          root_initiator_user_id: ctx.alice.id,
          causal_agent_ids: [agent.id],
          granted_by_id: human_actor(ctx.workspace, ctx.alice).id,
          inserted_at: DateTime.utc_now()
        })
      end)
    end)
    |> Task.await(10_000)
  end

  defp with_hook(hook, fun) do
    Process.put(:helmsman_test_hook, hook)

    try do
      fun.()
    after
      Process.delete(:helmsman_test_hook)
    end
  end

  describe "concurrent writes (own connections)" do
    test "the assignee changes before the task row is locked (scenario)" do
      ctx = committed_ctx()

      hook = fn
        {:dispatch_targets, 1} -> reassign!(ctx, "keel/qa")
        _other -> :ok
      end

      result =
        CommittedData.unboxed(fn ->
          with_hook(hook, fn -> Tasks.transition(ctx.bob_scope, ctx.task.ident, :in_progress) end)
        end)

      assert {:ok, %{dispatch: [%Outcome{agent: "keel/qa", trigger: :reopen, result: :queued}]}} =
               result

      CommittedData.unboxed(fn ->
        qa = agent_actor(ctx.workspace, "keel/qa")

        assert [%Run{agent_id: agent_id, status: :queued}] =
                 Repo.all(
                   from(r in Run, where: r.task_id == ^ctx.task.id and r.status == :queued)
                 )

        assert agent_id == qa.id
      end)
    end

    test "a change before every check: busy, nothing written" do
      ctx = committed_ctx()

      hook = fn
        {:dispatch_targets, n} -> reassign!(ctx, "keel/a#{n}")
        _other -> :ok
      end

      result =
        CommittedData.unboxed(fn ->
          with_hook(hook, fn ->
            Tasks.transition(ctx.bob_scope, ctx.task.ident, :in_progress, %{
              feedback: %{kind: "review", content: "again"}
            })
          end)
        end)

      assert result == {:error, :busy}

      CommittedData.unboxed(fn ->
        assert %TaskRow{status: :done, feedback_count: 0} = Repo.get!(TaskRow, ctx.task.id)
        assert Repo.all(from(f in Entry, where: f.task_id == ^ctx.task.id)) == []

        assert [%TaskEvent{to_status: :new}] =
                 Repo.all(from(e in TaskEvent, where: e.task_id == ^ctx.task.id))
      end)
    end

    test "a mentioned agent is disabled at the same time: both finish (scenario)" do
      ctx = committed_ctx()
      parent = self()

      hook = fn
        {:dispatch_targets, 1} ->
          writer = self()

          spawn(fn ->
            result =
              CommittedData.unboxed(fn ->
                send(writer, {:disabler, CommittedData.backend_pid()})
                Agents.disable(ctx.alice_scope, "keel/review")
              end)

            send(parent, {:disabled, result})
          end)

          # The disabler waits for the share lock this round holds.
          assert_receive {:disabler, pid}, 5_000
          Task.async(fn -> CommittedData.await_lock_wait(pid) end) |> Task.await(5_000)

        _other ->
          :ok
      end

      writer =
        Task.async(fn ->
          CommittedData.unboxed(fn ->
            with_hook(hook, fn ->
              Feedback.add(ctx.alice_scope, ctx.task.ident, %{content: "@keel/review look"})
            end)
          end)
        end)

      assert {:ok, entry} = Task.await(writer, 5_000)
      assert_receive {:disabled, {:ok, _agent}}, 5_000

      assert [%{agent: "keel/review", result: "queued", run_id: id}] =
               Feedback.view(entry).dispatch

      CommittedData.unboxed(fn -> assert %Run{status: :cancelled} = Repo.get!(Run, id) end)
    end
  end

  describe "in the sandbox" do
    setup do
      pid = Sandbox.start_owner!(Repo, shared: false)
      on_exit(fn -> Sandbox.stop_owner(pid) end)
      ctx = dispatch_fixture()
      managed_agent_fixture(ctx.alice_scope, %{name: "keel/qa"})
      Map.put(ctx, :qa, agent_actor(ctx.workspace, "keel/qa"))
    end

    test "disabled first: the mention is skipped", ctx do
      task = task_fixture(ctx.alice_scope, ctx.project.key)
      {:ok, _} = Agents.disable(ctx.alice_scope, "keel/qa")
      {:ok, entry} = Feedback.add(ctx.alice_scope, task.ident, %{content: "@keel/qa ?"})

      assert [%{agent: "keel/qa", result: "skipped", reason: "agent_disabled"}] =
               Feedback.view(entry).dispatch
    end

    test "busy after 3 rounds leaves no callback behind", ctx do
      ids = [ctx.agent.id, ctx.qa.id, ctx.alice_scope.actor.id]
      counter = :counters.new(1, [])

      result =
        Tx.run(fn ->
          result =
            Targets.with_locked(
              ctx.workspace.id,
              fn -> [] end,
              fn -> {:ok, :task} end,
              fn :task ->
                :counters.add(counter, 1, 1)
                # A new agent each round (the third is a person: never locked).
                {[Enum.at(ids, :counters.get(counter, 1) - 1) + 1_000_000], nil}
              end
            )

          assert Process.get({Tx, :after_commit}) == []
          result
        end)

      assert result == {:error, :busy}
      assert :counters.get(counter, 1) == 3
    end

    test "inside an outer transaction, a second round succeeds", ctx do
      round = :counters.new(1, [])

      result =
        Tx.run(fn ->
          Tx.run(fn ->
            {:ok,
             Targets.with_locked(
               ctx.workspace.id,
               fn -> [ctx.agent.id] end,
               fn -> {:ok, :task} end,
               fn :task ->
                 :counters.add(round, 1, 1)
                 {[ctx.qa.id], :value}
               end
             )}
          end)
        end)

      assert result == {:ok, {:ok, :task, :value}}
      assert :counters.get(round, 1) == 2
    end

    test "a candidate gone before the lock is not locked", ctx do
      gone = agent_fixture(ctx.workspace, ctx.alice, "keel/gone")

      result =
        Tx.run(fn ->
          Targets.with_locked(
            ctx.workspace.id,
            fn ->
              Repo.delete_all(from(a in Helmsman.Actors.Actor, where: a.id == ^gone.id))
              [gone.id]
            end,
            fn -> {:ok, :task} end,
            fn :task -> {[gone.id], nil} end
          )
        end)

      assert result == {:error, :busy}
    end

    test "an error locking the task is returned" do
      assert {:error, :not_found} =
               Tx.run(fn ->
                 Targets.with_locked(1, fn -> [] end, fn -> {:error, :not_found} end, fn _ ->
                   {[], nil}
                 end)
               end)
    end
  end
end
