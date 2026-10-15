defmodule Helmsman.Squads.EpicWatchLimitsTest do
  # improve-squad-leader-orchestration 2.3: squad-orchestration 「停滞唤醒的
  # 去重与上限」 (decision 12).
  use Helmsman.DataCase, async: false
  use Oban.Testing, repo: Helmsman.Repo

  import Helmsman.OrchestrationFixtures
  import Helmsman.RunsFixtures

  alias Helmsman.Actors.Actor
  alias Helmsman.{Feedback, Repo, Tasks}
  alias Helmsman.Feedback.Entry
  alias Helmsman.Runs
  alias Helmsman.Runs.{Retry, Run}
  alias Helmsman.Squads.{EpicWatch, EpicWatchCheck}
  alias Helmsman.Squads.Workers.EpicWatch, as: Job
  alias Helmsman.Tasks.{Task, TaskEvent}

  setup do
    ctx = orchestration_fixture()
    finish!()
    Repo.delete_all(Oban.Job)
    previous = Application.get_env(:helmsman, EpicWatch)
    on_exit(fn -> Application.put_env(:helmsman, EpicWatch, previous || []) end)
    ctx
  end

  # The leader's runs (and any other) end without changing anything.
  defp finish!,
    do:
      Repo.update_all(from(r in Run, where: r.status in [:queued, :claimed, :running]),
        set: [status: :succeeded]
      )

  defp check(ctx), do: EpicWatch.check(ctx.epic.id)

  # Moves the whole history `minutes` into the past: the order of events,
  # feedback and triggers is kept, the minimum interval is passed.
  defp age!(ctx, minutes) do
    ids = [
      ctx.epic.id | Repo.all(from(t in Task, where: t.epic_id == ^ctx.epic.id, select: t.id))
    ]

    shift = "interval '#{minutes} minutes'"

    Repo.query!(
      "UPDATE task_events SET inserted_at = inserted_at - #{shift} WHERE task_id = ANY($1)",
      [ids]
    )

    Repo.query!(
      "UPDATE feedback SET inserted_at = inserted_at - #{shift} WHERE task_id = ANY($1)",
      [ids]
    )

    Repo.query!(
      "UPDATE epic_watch_checks SET woken_at = woken_at - #{shift} WHERE epic_id = $1",
      [ctx.epic.id]
    )

    for run <- Repo.all(from(r in Run, where: r.task_id == ^ctx.epic.id)) do
      triggers =
        Enum.map(run.triggers, fn
          %{"kind" => "epic_stalled", "at" => at} = t ->
            {:ok, at, _} = DateTime.from_iso8601(at)
            %{t | "at" => at |> DateTime.add(-minutes * 60, :second) |> DateTime.to_iso8601()}

          t ->
            t
        end)

      Repo.update_all(from(r in Run, where: r.id == ^run.id), set: [triggers: triggers])
    end
  end

  defp wakes(ctx) do
    from(r in Run, where: r.task_id == ^ctx.epic.id, select: r.triggers)
    |> Repo.all()
    |> List.flatten()
    |> Enum.count(&(&1["kind"] == "epic_stalled"))
  end

  defp cap_notes(ctx) do
    Repo.all(
      from(f in Entry,
        join: a in Actor,
        on: a.id == f.author_id,
        where: f.task_id == ^ctx.epic.id and a.kind == :system,
        select: f
      )
    )
  end

  defp person_writes!(ctx),
    do: {:ok, _} = Feedback.add(ctx.alice_scope, ctx.epic.ident, %{content: "Do s2 first"})

  # A failed run on s2: its latest run changes (a new signature).
  defp failed_attempt!(ctx), do: run_fixture(ctx.review, %{task_id: ctx.s2.id, status: :failed})

  test "the leader judged waiting right: not woken again", ctx do
    assert check(ctx) == :woken
    finish!()
    age!(ctx, 20)
    assert check(ctx) == :same_signature
    assert wakes(ctx) == 1
  end

  test "too soon: checked again when the interval ends", ctx do
    assert check(ctx) == :woken
    finish!()
    person_writes!(ctx)
    Repo.delete_all(Oban.Job)
    assert check(ctx) == :too_soon

    assert [%Oban.Job{scheduled_at: at}] = all_enqueued(worker: Job)
    assert DateTime.diff(at, DateTime.utc_now()) in (14 * 60)..(15 * 60)
  end

  test "max_consecutive 0: never woken, no note", ctx do
    Application.put_env(:helmsman, EpicWatch, max_consecutive: 0)
    assert check(ctx) == :capped
    assert wakes(ctx) == 0
    assert cap_notes(ctx) == []
  end

  test "cycles: a person's new guidance wakes once more, then dedupes again", ctx do
    assert check(ctx) == :woken
    finish!()
    age!(ctx, 20)
    assert check(ctx) == :same_signature

    person_writes!(ctx)
    age!(ctx, 20)
    assert check(ctx) == :woken
    finish!()
    age!(ctx, 20)
    assert check(ctx) == :same_signature
    assert wakes(ctx) == 2
  end

  test "capped after 3 in a cycle: one note; notes and agents do not reopen it", ctx do
    for _ <- 1..3 do
      failed_attempt!(ctx)
      age!(ctx, 20)
      assert check(ctx) == :woken
      finish!()
    end

    failed_attempt!(ctx)
    age!(ctx, 20)
    assert check(ctx) == :capped
    assert [%Entry{content: content, dispatch: [%{"reason" => "stall_capped"}]}] = cap_notes(ctx)

    assert content =~
             "Helmsman stopped waking keel/lead (leader of web-team): #{ctx.epic.ident} stalled 3 times"

    assert content =~ "#{ctx.s3.ident} (unassigned)"

    # An agent's feedback, the note itself: still capped, no second note.
    {scope, _run} = leader_run(ctx, ctx.lead, ctx.epic)
    {:ok, _} = Feedback.add(scope, ctx.epic.ident, %{content: "Waiting"})
    finish!()
    age!(ctx, 20)
    assert check(ctx) == :capped
    assert length(cap_notes(ctx)) == 1

    # A person: a new cycle, the same flow works again.
    person_writes!(ctx)
    age!(ctx, 20)
    assert check(ctx) == :woken
  end

  test "a step finishing starts a new cycle, the idle steps unchanged", ctx do
    bob = human_actor(ctx.workspace, ctx.bob)

    {:ok, s4} =
      Tasks.create(ctx.alice_scope, ctx.project.key, %{
        title: "Bob",
        epic: ctx.epic.ident,
        assignee: bob.name
      })

    assert check(ctx) == :woken
    finish!()
    age!(ctx, 20)
    assert check(ctx) == :same_signature

    Repo.update_all(from(t in Task, where: t.id == ^s4.id), set: [status: :done])

    Repo.insert!(%TaskEvent{
      workspace_id: s4.workspace_id,
      task_id: s4.id,
      from_status: :new,
      to_status: :done,
      actor_id: ctx.fe.id
    })

    age!(ctx, 20)
    assert check(ctx) == :woken
  end

  describe "the history is the wakes, not the runs' triggers" do
    defp recorded(ctx), do: Repo.get_by!(EpicWatchCheck, epic_id: ctx.epic.id)

    defp stalled_run(ctx),
      do: Repo.one!(from(r in Run, where: r.task_id == ^ctx.epic.id and r.status == :queued))

    test "a retry copying the trigger is not a second wake", ctx do
      Application.put_env(:helmsman, EpicWatch, min_interval_minutes: 0, max_consecutive: 2)
      assert check(ctx) == :woken
      first = stalled_run(ctx)

      Repo.update_all(from(r in Run, where: r.id == ^first.id),
        set: [status: :failed, failure_reason: :provider_network]
      )

      assert {:ok, :retried} = Retry.perform(first.id)
      retry = Repo.one!(from(r in Run, where: r.retry_of_id == ^first.id))
      assert Enum.any?(retry.triggers, &(&1["kind"] == "epic_stalled"))
      finish!()

      failed_attempt!(ctx)
      assert check(ctx) == :woken
      assert recorded(ctx).wakes == 2
      finish!()
      failed_attempt!(ctx)
      assert check(ctx) == :capped
    end

    test "a wake pruned at claim still counts and spaces the next", ctx do
      import Helmsman.RunLifecycleFixtures

      assert check(ctx) == :woken
      stalled = stalled_run(ctx)

      manual = %{
        "kind" => "manual",
        "at" => DateTime.to_iso8601(DateTime.utc_now()),
        "by_actor_id" => ctx.lead.id,
        "initiator_user_id" => ctx.alice.id,
        "causal_agent_ids" => [ctx.lead.id]
      }

      source =
        run_fixture(ctx.lead, %{
          task_id: ctx.epic.id,
          squad_id: ctx.squad.id,
          status: :failed,
          triggers: [manual],
          capabilities: stalled.capabilities
        })

      assert {:ok, _} = Runs.retry(ctx.alice_scope, source.id)
      step_run = run_fixture(ctx.fe, %{task_id: ctx.s1.id, status: :queued})
      claim!(ctx.lead)
      claimed = Repo.get!(Run, stalled.id)
      assert claimed.status == :claimed
      refute Enum.any?(claimed.triggers, &(&1["kind"] == "epic_stalled"))
      Repo.update_all(from(r in Run, where: r.id == ^step_run.id), set: [status: :succeeded])
      finish!()

      assert check(ctx) == :too_soon
      assert recorded(ctx).wakes == 1
    end

    test "checks one after another count one wake", ctx do
      assert check(ctx) == :woken
      assert check(ctx) in [:not_stalled, :same_signature]
      finish!()
      assert check(ctx) == :same_signature
      assert %EpicWatchCheck{wakes: 1, result: "same_signature"} = recorded(ctx)
    end
  end

  test "the signature: not the order of steps, but assignees and runs", ctx do
    snapshot = EpicWatch.snapshot(Repo.reload!(ctx.epic))
    sig = EpicWatch.signature(snapshot)
    assert EpicWatch.signature(%{snapshot | steps: Enum.reverse(snapshot.steps)}) == sig

    failed_attempt!(ctx)
    refute EpicWatch.signature(EpicWatch.snapshot(Repo.reload!(ctx.epic))) == sig

    {:ok, _} = Tasks.update(ctx.alice_scope, ctx.s3.ident, %{assignee: "keel/qa", start: false})
    snapshot2 = EpicWatch.snapshot(Repo.reload!(ctx.epic))
    refute EpicWatch.signature(snapshot2) == EpicWatch.signature(snapshot)
  end
end
