defmodule Helmsman.Dispatch.SquadTargetsTest do
  # add-squads 2.1: the locks of a squad's trigger (squad-dispatch "小队触发
  # 的加锁", decision 6). The concurrent writes commit on connections of
  # their own.
  use ExUnit.Case, async: false

  import Ecto.Query
  import Helmsman.AgentsFixtures
  import Helmsman.ProjectsFixtures
  import Helmsman.RunsFixtures
  import Helmsman.SquadsFixtures

  alias Helmsman.{CommittedData, Feedback, Repo, Squads, Tasks, Tx}
  alias Helmsman.Feedback.Entry
  alias Helmsman.Runs.{Outcome, Run, TaskGrant}
  alias Helmsman.Squads.Member
  alias Helmsman.Tasks.Task, as: TaskRow

  @moduletag timeout: 60_000

  setup do
    ctx =
      CommittedData.unboxed(fn ->
        ctx = squads_fixture()

        for name <- ~w(keel/x keel/x2 keel/x3 keel/x4),
            do:
              managed_agent_fixture(ctx.alice_scope, %{
                name: name,
                runtime_id: ctx.runtime_id,
                access: "owner_only"
              })

        # bob may trigger every member but those added here.
        {:ok, _} = Helmsman.Agents.update(ctx.alice_scope, "keel/qa", %{access: "workspace"})
        Map.put(ctx, :bos12, task_fixture(ctx.alice_scope, ctx.project.key))
      end)

    on_exit(fn -> CommittedData.delete_user_data!([ctx.alice.id, ctx.bob.id, ctx.carol.id]) end)
    ctx
  end

  # Adds `name` to the squad directly, on a connection of its own, and
  # commits: what a concurrent change of the members leaves.
  defp add_member!(ctx, name) do
    Task.async(fn ->
      CommittedData.unboxed(fn ->
        agent = agent_actor(ctx.workspace, name)

        Repo.insert!(%Member{
          workspace_id: ctx.workspace.id,
          squad_id: ctx.squad.id,
          actor_id: agent.id,
          role_note: "",
          position: 10 + rem(agent.id, 1000),
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

  defp assign_as_bob(ctx),
    do: Tasks.update(ctx.bob_scope, ctx.bos12.ident, %{assignee: "web-team"})

  defp runs(ctx),
    do:
      CommittedData.unboxed(fn ->
        Repo.all(from(r in Run, where: r.task_id == ^ctx.bos12.id))
      end)

  test "a member added between the guess and the squad lock is checked", ctx do
    hook = fn
      {:squad_rows, 1} -> add_member!(ctx, "keel/x")
      _other -> :ok
    end

    result = CommittedData.unboxed(fn -> with_hook(hook, fn -> assign_as_bob(ctx) end) end)

    assert {:ok,
            %{dispatch: [%Outcome{result: :skipped, reason: :unauthorized, refused: refused}]}} =
             result

    assert refused == ["keel/x"]
    assert runs(ctx) == []
  end

  test "members changing in every round: busy, nothing written", ctx do
    names = %{1 => "keel/x", 2 => "keel/x2", 3 => "keel/x3"}

    hook = fn
      {:squad_rows, n} -> add_member!(ctx, names[n])
      _other -> :ok
    end

    result = CommittedData.unboxed(fn -> with_hook(hook, fn -> assign_as_bob(ctx) end) end)
    assert result == {:error, :busy}

    CommittedData.unboxed(fn ->
      assert %TaskRow{assignee_id: nil} = Repo.get!(TaskRow, ctx.bos12.id)
      assert Repo.all(from(g in TaskGrant, where: g.task_id == ^ctx.bos12.id)) == []
    end)

    assert runs(ctx) == []
  end

  test "creating a task: members changing in every round: busy, nothing written", ctx do
    names = %{1 => "keel/x", 2 => "keel/x2", 3 => "keel/x3"}

    hook = fn
      {:squad_rows, n} -> add_member!(ctx, names[n])
      _other -> :ok
    end

    result =
      CommittedData.unboxed(fn ->
        with_hook(hook, fn ->
          Tasks.create(ctx.bob_scope, ctx.project.key, %{title: "Busy", assignee: "web-team"})
        end)
      end)

    assert result == {:error, :busy}

    CommittedData.unboxed(fn ->
      assert Repo.all(from(t in TaskRow, where: t.title == "Busy")) == []
      assert Repo.all(from(g in TaskGrant, where: g.workspace_id == ^ctx.workspace.id)) == []
    end)
  end

  test "a mention: a member added before the task lock is checked; busy after 3 rounds", ctx do
    hook = fn
      {:dispatch_targets, 1} -> add_member!(ctx, "keel/x")
      _other -> :ok
    end

    {:ok, entry} =
      CommittedData.unboxed(fn ->
        with_hook(hook, fn ->
          Feedback.add(ctx.bob_scope, ctx.bos12.ident, %{content: "@web-team ?"})
        end)
      end)

    assert [%{result: "skipped", reason: "unauthorized", refused: ["keel/x"]}] =
             CommittedData.unboxed(fn -> Feedback.view(entry).dispatch end)

    names = %{1 => "keel/x2", 2 => "keel/x3", 3 => "keel/x4"}

    hook = fn
      {:dispatch_targets, n} -> add_member!(ctx, names[n])
      _other -> :ok
    end

    result =
      CommittedData.unboxed(fn ->
        with_hook(hook, fn ->
          Feedback.add(ctx.bob_scope, ctx.bos12.ident, %{content: "@web-team again"})
        end)
      end)

    assert result == {:error, :busy}

    CommittedData.unboxed(fn ->
      assert [_] = Repo.all(from(f in Entry, where: f.task_id == ^ctx.bos12.id))
    end)
  end

  describe "a change of the squad racing an assignment (own connections)" do
    defp start(fun, hold?) do
      parent = self()

      fun = if hold?, do: held_open(fun, parent), else: fun

      Task.async(fn ->
        CommittedData.unboxed(fn ->
          send(parent, {:backend, self(), CommittedData.backend_pid()})
          fun.()
        end)
      end)
    end

    defp held_open(fun, parent), do: fn -> Tx.run(fn -> hold(fun.(), parent) end) end

    defp hold(result, parent) do
      send(parent, {:held, self()})

      receive do
        :continue -> result
      end
    end

    defp race(first, second) do
      first = start(first, true)
      %Task{pid: pid} = first
      assert_receive {:backend, ^pid, _}, 5_000
      assert_receive {:held, ^pid}, 5_000

      second = start(second, false)
      %Task{pid: pid2} = second
      assert_receive {:backend, ^pid2, backend}, 5_000
      CommittedData.await_lock_wait(backend)
      send(first.pid, :continue)
      {Task.await(first, 5_000), Task.await(second, 5_000)}
    end

    defp add_x(ctx) do
      fn ->
        {:ok, squad} = Squads.get(ctx.alice_scope, "web-team")
        members = Enum.map(squad.members, &%{name: &1.name, role_note: &1.role_note})
        Squads.update(ctx.alice_scope, "web-team", %{members: members ++ [%{name: "keel/x"}]})
      end
    end

    test "the member is added first: skipped, keel/x refused", ctx do
      assert {{:ok, _}, {:ok, task}} = race(add_x(ctx), fn -> assign_as_bob(ctx) end)

      assert [%Outcome{result: :skipped, reason: :unauthorized, refused: ["keel/x"]}] =
               task.dispatch
    end

    test "the assignment first: dispatched with the old members", ctx do
      assert {{:ok, task}, {:ok, _}} = race(fn -> assign_as_bob(ctx) end, add_x(ctx))
      assert [%Outcome{result: :queued, squad: "web-team"}] = task.dispatch
    end
  end
end
