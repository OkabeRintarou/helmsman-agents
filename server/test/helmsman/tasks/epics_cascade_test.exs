defmodule Helmsman.Tasks.EpicsCascadeTest do
  # `add-epics` decisions 6-7: epics follow their steps.
  use Helmsman.DataCase, async: true

  import Helmsman.AgentsFixtures
  import Helmsman.ProjectsFixtures
  import Helmsman.RunsFixtures

  alias Helmsman.{Locks, Tasks, Tx}
  alias Helmsman.Runs.Run
  alias Helmsman.Tasks.{Epics, Task, TaskEvent}

  @tests %{command: "mix test", passed: true, summary: "1 test, 0 failures"}

  setup do
    ctx = dispatch_fixture()
    scope = ctx.alice_scope
    project_fixture(scope, key: "BOS")
    project_fixture(scope, key: "WEB")
    Map.merge(ctx, %{scope: scope, keel: %{scope | actor: ctx.agent}})
  end

  defp epic_fixture(scope, attrs \\ %{}),
    do: task_fixture(scope, "BOS", Map.merge(%{kind: "epic"}, attrs))

  defp steps(scope, epic, n), do: for(_ <- 1..n, do: task_fixture(scope, "WEB", epic: epic.ident))

  defp move(scope, task, path) do
    Enum.each(path, fn to ->
      opts = if to == :verified, do: %{tests: @tests}, else: %{}
      {:ok, _} = Tasks.transition(scope, task.ident, to, opts)
    end)
  end

  # Arrange statuses without going through the state machine.
  defp force_status(task, status),
    do: Repo.update_all(from(t in Task, where: t.id == ^task.id), set: [status: status])

  defp reload(task), do: Repo.get!(Task, task.id)

  defp last_event(task) do
    Repo.one!(
      from(e in TaskEvent,
        where: e.task_id == ^task.id,
        order_by: [desc: e.id],
        limit: 1,
        preload: :actor
      )
    )
  end

  defp event_count(task),
    do: Repo.aggregate(from(e in TaskEvent, where: e.task_id == ^task.id), :count)

  describe "decision table (6 epic statuses x step sets x causes)" do
    # The steps left after the cause; the expected result for
    # :step_transition and :step_added. :step_removed never reopens.
    @combos %{
      empty: [],
      all_cancelled: [:cancelled, :cancelled],
      with_rejected: [:done, :rejected],
      mixed: [:done, :in_progress],
      finished: [:done, :cancelled]
    }
    @expected %{
      new: %{finished: :done},
      in_progress: %{finished: :done},
      done: %{with_rejected: :in_progress, mixed: :in_progress},
      verified: %{with_rejected: :in_progress, mixed: :in_progress},
      cancelled: %{},
      rejected: %{}
    }
    @comments %{
      {:done, :step_transition} => "all steps completed (auto)",
      {:done, :step_added} => "all steps completed (auto)",
      {:done, :step_removed} => "all steps completed (auto)",
      {:in_progress, :step_transition} => "step reopened (auto)",
      {:in_progress, :step_added} => "step added (auto)"
    }

    for epic_status <- Map.keys(@expected) do
      test "epic #{epic_status}", ctx do
        epic_status = unquote(epic_status)

        for {combo, statuses} <- combos(),
            cause <- [:step_transition, :step_added, :step_removed] do
          check_case(ctx, epic_status, statuses, cause, expected(epic_status, combo, cause))
        end
      end
    end

    defp combos, do: @combos

    defp expected(epic_status, combo, cause) do
      case {@expected |> Map.fetch!(epic_status) |> Map.get(combo), cause} do
        {:in_progress, :step_removed} -> nil
        {result, _cause} -> result
      end
    end

    defp check_case(ctx, epic_status, statuses, cause, result) do
      epic = epic_fixture(ctx.scope)

      for status <- statuses do
        step = task_fixture(ctx.scope, "WEB", epic: epic.ident)
        force_status(step, status)
      end

      force_status(epic, epic_status)
      before = reload(epic)
      events = event_count(epic)

      {:ok, :ok} =
        Tx.run(fn ->
          Locks.graph!(ctx.workspace.id)
          attrs = %{actor_id: ctx.agent.id, source_run_id: nil}
          {:ok, Epics.recompute(epic.id, cause, attrs)}
        end)

      after_ = reload(epic)
      label = "#{epic_status} #{inspect(statuses)} #{cause}"
      assert after_.lock_version == before.lock_version, label

      if result do
        assert after_.status == result, label
        event = last_event(epic)

        assert %{
                 auto: true,
                 commits: [],
                 tests: nil,
                 feedback_id: nil,
                 source_run_id: nil
               } = event,
               label

        assert {event.from_status, event.to_status} == {epic_status, result}, label
        assert event.comment == @comments[{result, cause}], label
        assert event.actor_id == ctx.agent.id, label
      else
        assert after_.status == epic_status, label
        assert event_count(epic) == events, label
      end
    end
  end

  describe "following the steps" do
    test "the last step done: the epic is done, as keel/dev", ctx do
      epic = epic_fixture(ctx.scope)
      [a, b, c] = steps(ctx.scope, epic, 3)
      move(ctx.scope, epic, [:in_progress])
      epic = reload(epic)
      move(ctx.scope, a, [:in_progress, :done])
      move(ctx.scope, b, [:in_progress, :done])
      assert reload(epic).status == :in_progress

      move(ctx.keel, c, [:in_progress, :done])

      assert reload(epic).status == :done
      assert reload(epic).lock_version == epic.lock_version

      {:ok, read} = Tasks.get(ctx.scope, epic.ident)

      assert %{
               from: "in_progress",
               to: "done",
               actor: %{name: "keel/dev"},
               auto: true,
               comment: "all steps completed (auto)",
               commits: [],
               tests: nil
             } = List.last(Tasks.detail(read).history)
    end

    test "all steps cancelled: the epic stays", ctx do
      epic = epic_fixture(ctx.scope)
      for step <- steps(ctx.scope, epic, 2), do: move(ctx.scope, step, [:cancelled])
      assert reload(epic).status == :new
      assert event_count(epic) == 1
    end

    test "a step sent back: the verified epic is in progress again", ctx do
      epic = epic_fixture(ctx.scope)
      [step] = steps(ctx.scope, epic, 1)
      move(ctx.scope, step, [:in_progress, :done])
      assert reload(epic).status == :done
      move(ctx.scope, epic, [:verified])

      move(ctx.scope, step, [:in_progress])

      assert reload(epic).status == :in_progress
      assert %{comment: "step reopened (auto)", auto: true} = last_event(epic)
    end

    test "a new step under a done epic", ctx do
      epic = epic_fixture(ctx.scope)
      [step] = steps(ctx.scope, epic, 1)
      move(ctx.scope, step, [:in_progress, :done])
      assert reload(epic).status == :done

      task_fixture(ctx.scope, "BOS", epic: epic.ident)

      assert reload(epic).status == :in_progress

      assert %{comment: "step added (auto)", from_status: :done, actor_id: actor_id} =
               last_event(epic)

      assert actor_id == ctx.scope.actor.id
    end

    test "attaching an existing open step to a verified epic", ctx do
      epic = epic_fixture(ctx.scope)
      [step] = steps(ctx.scope, epic, 1)
      move(ctx.scope, step, [:in_progress, :done])
      move(ctx.scope, epic, [:verified])
      other = task_fixture(ctx.scope, "WEB")

      {:ok, _} = Tasks.update(ctx.keel, other.ident, %{epic: epic.ident})

      assert reload(epic).status == :in_progress
      assert %{comment: "step added (auto)", from_status: :verified} = last_event(epic)
      assert last_event(epic).actor_id == ctx.agent.id
    end

    test "detaching the only open step completes the epic", ctx do
      epic = epic_fixture(ctx.scope)
      [done, open] = steps(ctx.scope, epic, 2)
      move(ctx.scope, epic, [:in_progress])
      move(ctx.scope, done, [:in_progress, :done])

      {:ok, _} = Tasks.update(ctx.scope, open.ident, %{epic: ""})

      assert reload(epic).status == :done

      assert %{comment: "all steps completed (auto)", from_status: :in_progress} =
               last_event(epic)
    end

    test "detaching never reopens; empty or cancelled leftovers change nothing", ctx do
      epic = epic_fixture(ctx.scope)
      [done, cancelled] = steps(ctx.scope, epic, 2)
      move(ctx.scope, done, [:in_progress, :done])
      move(ctx.scope, cancelled, [:cancelled])
      assert reload(epic).status == :done
      events = event_count(epic)

      {:ok, _} = Tasks.update(ctx.scope, done.ident, %{epic: ""})
      assert reload(epic).status == :done
      {:ok, _} = Tasks.update(ctx.scope, cancelled.ident, %{epic: ""})
      assert reload(epic).status == :done
      assert event_count(epic) == events

      # An in-progress epic left with cancelled steps only stays as it is.
      other = epic_fixture(ctx.scope)
      [done, cancelled] = steps(ctx.scope, other, 2)
      move(ctx.scope, other, [:in_progress])
      move(ctx.scope, cancelled, [:cancelled])
      move(ctx.scope, done, [:in_progress])
      {:ok, _} = Tasks.update(ctx.scope, done.ident, %{epic: ""})
      assert reload(other).status == :in_progress
    end

    test "moving a step recomputes both epics", ctx do
      first = epic_fixture(ctx.scope)
      second = epic_fixture(ctx.scope)
      [done] = steps(ctx.scope, first, 1)
      move(ctx.scope, done, [:in_progress, :done])
      assert reload(first).status == :done
      [open] = steps(ctx.scope, second, 1)
      move(ctx.scope, second, [:in_progress])
      [moving] = steps(ctx.scope, second, 1)
      move(ctx.scope, open, [:in_progress, :done])
      assert reload(second).status == :in_progress

      {:ok, _} = Tasks.update(ctx.scope, moving.ident, %{epic: first.ident})

      assert reload(first).status == :in_progress
      assert reload(second).status == :done
    end

    test "a cancelled epic stays cancelled", ctx do
      epic = epic_fixture(ctx.scope)
      [step] = steps(ctx.scope, epic, 1)
      move(ctx.scope, epic, [:cancelled])
      move(ctx.scope, step, [:in_progress, :done])
      assert reload(epic).status == :cancelled
    end
  end

  describe "runs" do
    test "an automatic transition in a run names the run", ctx do
      epic = epic_fixture(ctx.scope)
      [step] = steps(ctx.scope, epic, 1)
      move(ctx.scope, step, [:in_progress])

      run =
        run_fixture(ctx.agent, %{
          task_id: step.id,
          status: :running,
          capabilities: ["read", "write_task"]
        })

      {scope, _token} = run_scope_fixture(run)
      {:ok, _} = Tasks.transition(scope, step.ident, :done)

      assert %{auto: true, to_status: :done, source_run_id: run_id, actor_id: actor_id} =
               last_event(epic)

      assert run_id == run.id
      assert actor_id == ctx.agent.id
    end

    test "auto_claim recomputes the epic", ctx do
      epic = epic_fixture(ctx.scope)
      [done] = steps(ctx.scope, epic, 1)

      step =
        task_fixture(ctx.scope, "WEB", epic: epic.ident, assignee: "keel/dev", start: false)

      move(ctx.scope, epic, [:in_progress])
      move(ctx.scope, done, [:in_progress, :done])
      # A human may close an epic whose steps are still open.
      move(ctx.scope, epic, [:done])

      run = run_fixture(ctx.agent, %{task_id: step.id, status: :running})
      assert {:ok, :claimed} = Tasks.auto_claim_for_run(run)

      assert reload(epic).status == :in_progress

      assert %{
               comment: "step reopened (auto)",
               actor_id: actor_id,
               source_run_id: run_id
             } = last_event(epic)

      assert actor_id == ctx.agent.id
      assert run_id == run.id
    end

    test "a managed agent executing the epic is not woken", ctx do
      managed_agent_fixture(ctx.scope, %{name: "keel/lead"})
      epic = epic_fixture(ctx.scope, %{assignee: "keel/lead", start: false})
      [step] = steps(ctx.scope, epic, 1)
      move(ctx.scope, step, [:in_progress, :done])
      assert reload(epic).status == :done
      runs = Repo.aggregate(Run, :count)

      move(ctx.scope, step, [:in_progress])

      assert reload(epic).status == :in_progress
      assert Repo.aggregate(Run, :count) == runs

      assert %{rows: [[0]]} =
               Repo.query!("SELECT count(*) FROM oban_jobs WHERE worker LIKE '%ReconcilePR%'")
    end
  end
end

defmodule Helmsman.Tasks.EpicsCascadeRaceTest do
  # Each transition runs on a connection of its own outside the sandbox.
  use ExUnit.Case, async: false

  import Helmsman.AccountsFixtures
  import Helmsman.ProjectsFixtures
  import Helmsman.WorkspacesFixtures

  alias Helmsman.{CommittedData, Repo, Tasks}

  setup do
    tag = System.unique_integer([:positive])

    {owner, scope, epic, steps} =
      CommittedData.unboxed(fn ->
        owner = user_fixture(%{email: "owner-#{tag}@epics-race.test"})
        workspace = workspace_fixture(owner)
        scope = workspace_scope_fixture(owner, workspace)
        project_fixture(scope, key: "BOS")
        epic = task_fixture(scope, "BOS", kind: "epic")
        steps = for _ <- 1..3, do: task_fixture(scope, "BOS", epic: epic.ident)

        for step <- steps, do: {:ok, _} = Tasks.transition(scope, step.ident, "in_progress")
        {:ok, _} = Tasks.transition(scope, hd(steps).ident, "done")
        {owner, scope, epic, tl(steps)}
      end)

    on_exit(fn -> CommittedData.delete_user_data!([owner.id]) end)
    %{scope: scope, epic: epic, steps: steps}
  end

  test "the last two steps done at once: one automatic done", ctx do
    parent = self()

    racers =
      for step <- ctx.steps do
        Task.async(fn ->
          CommittedData.unboxed(fn ->
            send(parent, {:ready, self()})

            receive do
              :go -> send(parent, {:result, Tasks.transition(ctx.scope, step.ident, "done")})
            end
          end)
        end)
      end

    for _ <- racers, do: assert_receive({:ready, _pid}, 5_000)
    Enum.each(racers, &send(&1.pid, :go))

    assert_receive {:result, {:ok, %{status: "done"}}}, 5_000
    assert_receive {:result, {:ok, %{status: "done"}}}, 5_000
    Task.await_many(racers, 5_000)

    %{rows: rows} =
      CommittedData.unboxed(fn ->
        Repo.query!(
          "SELECT from_status, auto, comment FROM task_events " <>
            "WHERE task_id = $1 AND to_status = 'done'",
          [ctx.epic.id]
        )
      end)

    assert rows == [["new", true, "all steps completed (auto)"]]
  end
end
