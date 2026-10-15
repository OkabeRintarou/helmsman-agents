defmodule Helmsman.Squads.EpicWatchTest do
  # improve-squad-leader-orchestration 2.2: squad-orchestration 「停滞唤醒」
  # 「停滞唤醒的复核」 (decisions 10, 11).
  use Helmsman.DataCase, async: false
  use Oban.Testing, repo: Helmsman.Repo

  import Helmsman.OrchestrationFixtures
  import Helmsman.RunLifecycleFixtures
  import Helmsman.RunsFixtures

  alias Helmsman.{Feedback, Repo, Tasks}
  alias Helmsman.Runs.{Run, TaskGrant, Triggers}
  alias Helmsman.Squads.{EpicWatch, EpicWatchCheck}
  alias Helmsman.Squads.Workers.EpicWatch, as: Job
  alias Helmsman.Tasks.Task

  setup do
    ctx = orchestration_fixture()
    end_runs()
    Repo.delete_all(Oban.Job)
    ctx
  end

  defp end_runs,
    do:
      Repo.update_all(from(r in Run, where: r.status in [:queued, :claimed, :running, :deferred]),
        set: [status: :succeeded]
      )

  defp check(ctx), do: perform_job(Job, %{epic_id: ctx.epic.id})

  defp stalled_runs(ctx),
    do:
      Repo.all(
        from(r in Run,
          where: r.task_id == ^ctx.epic.id and r.status == :queued,
          order_by: r.id
        )
      )

  defp attach_telemetry(ref) do
    parent = self()

    :telemetry.attach(
      "epic-watch-#{inspect(ref)}",
      [:helmsman, :epic_watch, :check],
      fn _e, _m, %{result: result}, _c -> send(parent, {:checked, result}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach("epic-watch-#{inspect(ref)}") end)
  end

  describe "停滞唤醒" do
    test "the callback did nothing: the leader is woken as the squad on the epic", ctx do
      assert :ok = check(ctx)

      assert [
               %Run{
                 agent_id: lead,
                 squad_id: squad,
                 lane: :work,
                 root_initiator_user_id: by,
                 triggers: [t]
               }
             ] =
               stalled_runs(ctx)

      assert {lead, squad, by} == {ctx.lead.id, ctx.squad.id, ctx.alice.id}
      assert %{"kind" => "epic_stalled", "idle_count" => 3, "signature" => sig} = t
      assert is_binary(sig)

      assert Enum.map(t["idle"], &{&1["task"], &1["reason"]}) == [
               {ctx.s1.ident, "start"},
               {ctx.s2.ident, "start"},
               {ctx.s3.ident, "assignment"}
             ]

      assert %EpicWatchCheck{result: "woken"} = Repo.get_by!(EpicWatchCheck, epic_id: ctx.epic.id)
    end

    test "a run ending, a transition and a person's feedback schedule a check", ctx do
      run = run_fixture(ctx.fe, %{task_id: ctx.s1.id, status: :succeeded})
      Helmsman.Tx.run(fn -> {:ok, Helmsman.Runs.after_ended([run])} end)
      assert_enqueued(worker: Job, args: %{epic_id: ctx.epic.id})
      Repo.delete_all(Oban.Job)

      {:ok, _} = Tasks.transition(ctx.alice_scope, ctx.s3.ident, :in_progress)
      assert_enqueued(worker: Job, args: %{epic_id: ctx.epic.id})
      Repo.delete_all(Oban.Job)

      {:ok, _} = Feedback.add(ctx.alice_scope, ctx.s2.ident, %{content: "Go on"})
      assert_enqueued(worker: Job, args: %{epic_id: ctx.epic.id})
      Repo.delete_all(Oban.Job)

      # An agent's feedback does not.
      {scope, _run} = leader_run(ctx, ctx.lead, ctx.epic)
      Repo.delete_all(Oban.Job)
      {:ok, _} = Feedback.add(scope, ctx.epic.ident, %{content: "Noted"})
      refute_enqueued(worker: Job)
    end

    test "a new event moves the waiting check later: still one job", ctx do
      :ok = EpicWatch.schedule([ctx.s1.id], 10)
      [%Oban.Job{scheduled_at: first}] = all_enqueued(worker: Job)
      :ok = EpicWatch.schedule([ctx.s2.id], 300)
      assert [%Oban.Job{scheduled_at: later}] = all_enqueued(worker: Job)
      assert DateTime.compare(later, first) == :gt
    end

    test "without the squad's assign grant: nothing queued, no_grant", ctx do
      attach_telemetry(make_ref())

      Repo.delete_all(
        from(g in TaskGrant, where: g.task_id == ^ctx.epic.id and g.kind == :assign)
      )

      assert :ok = check(ctx)
      assert stalled_runs(ctx) == []
      assert_received {:checked, :no_grant}
    end

    test "the epic done by its last step: not woken", ctx do
      Repo.update_all(from(t in Task, where: t.epic_id == ^ctx.epic.id), set: [status: :verified])
      Repo.update_all(from(t in Task, where: t.id == ^ctx.epic.id), set: [status: :done])
      assert :ok = check(ctx)
      assert stalled_runs(ctx) == []
    end

    test "epic_stalled is bound to the squad and not gated by dependencies", ctx do
      refute Triggers.dependency_gated?([%{"kind" => "epic_stalled"}])

      assert Triggers.bound_assignee(%{"kind" => "epic_stalled"}, %{
               agent_id: ctx.lead.id,
               squad_id: ctx.squad.id
             }) == {:squad, ctx.squad.id}
    end
  end

  describe "停滞唤醒的复核" do
    test "a person started a step meanwhile: obsolete when claimed", ctx do
      :ok = check(ctx)
      [stalled] = stalled_runs(ctx)
      run_fixture(ctx.review, %{task_id: ctx.s2.id, status: :running})
      claim!(ctx.lead)
      assert %Run{status: :cancelled, failure_reason: :obsolete} = Repo.get!(Run, stalled.id)
    end

    test "still stalled: claimed", ctx do
      :ok = check(ctx)
      [stalled] = stalled_runs(ctx)
      claim!(ctx.lead)
      assert %Run{status: :claimed} = Repo.get!(Run, stalled.id)
    end
  end

  describe "the sweep" do
    setup do
      previous = Application.get_env(:helmsman, EpicWatch)
      on_exit(fn -> Application.put_env(:helmsman, EpicWatch, previous || []) end)
      :ok
    end

    # `n` more epics of web-team, in progress, each with an idle step, the
    # squad's grant removed (their checks end in no_grant). Inserted
    # directly: many of them.
    defp ungranted_epics(ctx, n) do
      now = DateTime.utc_now()
      base = Repo.one!(from(t in Task, select: max(t.seq)))

      rows = fn kind, seq, extra ->
        Map.merge(
          %{
            workspace_id: ctx.workspace.id,
            project_id: ctx.project.id,
            seq: seq,
            ident: "#{ctx.project.key}-#{seq}",
            title: "t#{seq}",
            description: "",
            status: :in_progress,
            priority: :medium,
            labels: [],
            kind: kind,
            created_by_id: human_actor(ctx.workspace, ctx.alice).id,
            lock_version: 1,
            feedback_seq: 0,
            feedback_count: 0,
            open_question: false,
            inserted_at: now,
            updated_at: now
          },
          extra
        )
      end

      {_, epics} =
        Repo.insert_all(
          Task,
          for(i <- 1..n, do: rows.(:epic, base + 2 * i, %{assignee_id: ctx.squad_actor.id})),
          returning: [:id, :seq]
        )

      Repo.insert_all(
        Task,
        for(
          e <- epics,
          do: rows.(:task, e.seq + 1, %{epic_id: e.id, status: :new, assignee_id: ctx.fe.id})
        )
      )

      Repo.update_all(from(p in Helmsman.Projects.Project, where: p.id == ^ctx.project.id),
        set: [task_seq: base + 2 * n + 1]
      )

      epics
    end

    # A real stalled epic created after them (the greatest ID), with the
    # squad's grant.
    defp granted_epic(ctx) do
      epic =
        Helmsman.ProjectsFixtures.task_fixture(ctx.alice_scope, ctx.project.key, %{kind: :epic})

      {:ok, _} = Tasks.update(ctx.alice_scope, epic.ident, %{assignee: "web-team", start: false})
      {:ok, _} = Tasks.transition(ctx.alice_scope, epic.ident, :in_progress)

      {:ok, _} =
        Tasks.create(ctx.alice_scope, ctx.project.key, %{
          title: "s",
          epic: epic.ident,
          assignee: "keel/fe",
          start: false
        })

      end_runs()
      Repo.delete_all(Oban.Job)
      Repo.reload!(epic)
    end

    defp round! do
      count = EpicWatch.sweep()
      jobs = all_enqueued(worker: Job)
      assert length(jobs) <= EpicWatch.config(:sweep_batch)
      Repo.delete_all(Oban.Job)
      for job <- jobs, do: :ok = perform_job(Job, job.args)
      count
    end

    test "fair: the 201st epic is checked and woken in the second round", ctx do
      Repo.delete_all(
        from(g in TaskGrant, where: g.task_id == ^ctx.epic.id and g.kind == :assign)
      )

      ungranted_epics(ctx, 199)
      last = granted_epic(ctx)

      assert round!() == 200
      assert Repo.all(from(r in Run, where: r.task_id == ^last.id)) == []
      round!()

      assert [%Run{triggers: [%{"kind" => "epic_stalled"}]}] =
               Repo.all(from(r in Run, where: r.task_id == ^last.id))
    end

    test "batches of 50: all 201 checked within 5 rounds", ctx do
      Application.put_env(:helmsman, EpicWatch, sweep_batch: 50)

      Repo.delete_all(
        from(g in TaskGrant, where: g.task_id == ^ctx.epic.id and g.kind == :assign)
      )

      ungranted_epics(ctx, 199)
      granted_epic(ctx)

      for _ <- 1..5, do: assert(round!() <= 50)
      assert Repo.aggregate(EpicWatchCheck, :count) == 201
    end
  end
end
