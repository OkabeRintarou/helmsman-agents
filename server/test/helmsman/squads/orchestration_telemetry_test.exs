defmodule Helmsman.Squads.OrchestrationTelemetryTest do
  # improve-squad-leader-orchestration 4.5 (decision 17): the counters of
  # orchestration writes and stall checks, and the events behind them as
  # the writes and checks of groups 1–2 emit them. Async: false — the stall
  # limits are read from the application environment.
  use Helmsman.DataCase, async: false

  import Helmsman.OrchestrationFixtures
  import Helmsman.ProjectsFixtures
  import Helmsman.RunsFixtures

  alias Helmsman.{Feedback, Links, Repo, Squads, Tasks}
  alias Helmsman.Runs.{Run, TaskGrant}
  alias Helmsman.Squads.EpicWatch
  alias Telemetry.Metrics.Counter

  @write [:helmsman, :orchestration, :write]
  @check [:helmsman, :epic_watch, :check]

  setup %{test: test} do
    ctx = orchestration_fixture()
    {scope, run} = leader_run(ctx, ctx.lead, ctx.s1)

    # Only the events of this test's process.
    parent = self()

    :telemetry.attach_many(
      "#{test}",
      [@write, @check],
      fn event, measurements, metadata, _config ->
        if self() == parent, do: send(parent, {event, measurements, metadata})
      end,
      nil
    )

    previous = Application.get_env(:helmsman, EpicWatch)

    on_exit(fn ->
      :telemetry.detach("#{test}")
      Application.put_env(:helmsman, EpicWatch, previous || [])
    end)

    Map.merge(ctx, %{scope: scope, run: run})
  end

  test "the counters by result" do
    metrics = Map.new(HelmsmanWeb.Telemetry.metrics(), &{&1.name, &1})

    assert %Counter{tags: [:action, :result]} =
             metrics[[:helmsman, :orchestration, :write, :count]]

    assert %Counter{tags: [:result]} = metrics[[:helmsman, :epic_watch, :check, :count]]
  end

  test "orchestration writes: each action and refusal", ctx do
    {:ok, _} = Tasks.update(ctx.scope, ctx.s3.ident, %{assignee: "keel/qa", start: false})
    assert_received {@write, %{count: 1}, %{action: :assign, result: :ok}}

    {:error, _} = Tasks.update(ctx.scope, ctx.s2.ident, %{title: "PPU only"})
    assert_received {@write, %{count: 1}, %{action: :assign, result: :fields}}

    {:ok, _} = Links.add(ctx.scope, ctx.s3.ident, ctx.s2.ident, "depends_on")
    assert_received {@write, %{count: 1}, %{action: :link, result: :ok}}

    {:error, _} = Links.add(ctx.scope, ctx.s3.ident, ctx.s2.ident, "replaces")
    assert_received {@write, %{count: 1}, %{action: :link, result: :link_type}}

    {:ok, _} = Links.remove(ctx.scope, ctx.s3.ident, ctx.s2.ident, "depends_on")
    assert_received {@write, %{count: 1}, %{action: :unlink, result: :ok}}

    {:ok, %{result: :queued}} = Squads.start_task(ctx.scope, ctx.s2.ident)
    assert_received {@write, %{count: 1}, %{action: :start, result: :ok}}

    other = task_fixture(ctx.alice_scope, ctx.project.key)
    {:error, _} = Squads.start_task(ctx.scope, other.ident)
    assert_received {@write, %{count: 1}, %{action: :start, result: :outside}}

    refute_received {@write, _, _}
  end

  test "a write that is not orchestration emits nothing", ctx do
    {:ok, _} = Tasks.update(ctx.alice_scope, ctx.s3.ident, %{assignee: "keel/qa", start: false})
    refute_received {@write, _, _}
  end

  describe "stall checks" do
    setup ctx do
      Repo.update_all(from(r in Run, where: r.status in [:queued, :claimed, :running]),
        set: [status: :succeeded]
      )

      ctx
    end

    test "woken, then too soon in a new cycle", ctx do
      assert EpicWatch.check(ctx.epic.id) == :woken
      assert_received {@check, %{count: 1}, %{result: :woken}}

      Repo.update_all(from(r in Run, where: r.status == :queued), set: [status: :succeeded])
      # A person's guidance opens a new cycle, within the minimum interval.
      {:ok, _} = Feedback.add(ctx.alice_scope, ctx.epic.ident, %{content: "Do s2 first"})
      assert EpicWatch.check(ctx.epic.id) == :too_soon
      assert_received {@check, %{count: 1}, %{result: :too_soon}}
    end

    test "woken, then the same signature", ctx do
      assert EpicWatch.check(ctx.epic.id) == :woken
      assert_received {@check, %{count: 1}, %{result: :woken}}

      Repo.update_all(from(r in Run, where: r.status == :queued), set: [status: :succeeded])
      # Past the minimum interval, the history kept in order.
      for table <- ~w(task_events feedback) do
        Repo.query!("UPDATE #{table} SET inserted_at = inserted_at - interval '20 minutes'")
      end

      Repo.query!("UPDATE epic_watch_checks SET woken_at = woken_at - interval '20 minutes'")

      assert EpicWatch.check(ctx.epic.id) == :same_signature
      assert_received {@check, %{count: 1}, %{result: :same_signature}}
    end

    test "not stalled while a step runs", ctx do
      run_fixture(ctx.review, %{task_id: ctx.s2.id, status: :running})

      assert EpicWatch.check(ctx.epic.id) == :not_stalled
      assert_received {@check, %{count: 1}, %{result: :not_stalled}}
    end

    test "without the squad's assign grant", ctx do
      Repo.delete_all(
        from(g in TaskGrant, where: g.task_id == ^ctx.epic.id and g.kind == :assign)
      )

      assert EpicWatch.check(ctx.epic.id) == :no_grant
      assert_received {@check, %{count: 1}, %{result: :no_grant}}
    end

    test "capped, and a task gone: skipped", ctx do
      Application.put_env(:helmsman, EpicWatch, max_consecutive: 0)
      assert EpicWatch.check(ctx.epic.id) == :capped
      assert_received {@check, %{count: 1}, %{result: :capped}}

      assert EpicWatch.check(-1) == :skipped
      assert_received {@check, %{count: 1}, %{result: :skipped}}
    end
  end
end
