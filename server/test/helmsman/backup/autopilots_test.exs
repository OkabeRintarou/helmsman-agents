defmodule Helmsman.Backup.AutopilotsTest do
  use Helmsman.DataCase, async: false
  use Oban.Testing, repo: Helmsman.Repo
  import Helmsman.AutopilotsFixtures
  import Helmsman.ProjectsFixtures
  alias Helmsman.{Autopilots, Backup}
  alias Helmsman.Autopilots.Record
  alias Helmsman.Autopilots.Workers.StartPending
  alias Helmsman.Runs.Run
  alias Helmsman.Tasks.Task

  setup do
    ctx = autopilots_fixture()

    path =
      Path.join(System.tmp_dir!(), "replace-autopilots-#{System.unique_integer([:positive])}.gz")

    old = Application.get_env(:helmsman, :backup_sandbox)
    Application.put_env(:helmsman, :backup_sandbox, true)

    on_exit(fn ->
      Application.put_env(:helmsman, :backup_sandbox, old)
      File.rm(path)
    end)

    {:ok, _} = Backup.export_to_file(ctx.workspace, path)
    Map.put(ctx, :path, path)
  end

  defp replace(ctx),
    do: Backup.import_file(ctx.alice_scope, ctx.path, mode: :replace, confirm: ctx.workspace.slug)

  test "replacement cancels started task trigger, preserves delivery dedup and resumes pending",
       ctx do
    view = autopilot_fixture(ctx.alice_scope, %{overlap: "queue"})
    {:ok, %{token: token}} = Autopilots.enable_webhook(ctx.alice_scope, view.id)
    {:ok, hash} = Autopilots.authenticate_webhook(view.id, token)

    {:ok, started} =
      Autopilots.fire_webhook(view.id, hash, "synthetic-delivery", "{}", "application/json")

    {:ok, pending} = Autopilots.run_now(ctx.alice_scope, view.id, "synthetic pending note")
    assert pending.status == :pending

    Repo.update_all(from(a in Autopilots.Autopilot, where: a.id == ^view.id),
      set: [consecutive_failures: 3]
    )

    assert {:ok, _} = replace(ctx)
    cancelled = Repo.get!(Record, started.id)
    assert cancelled.status == :cancelled and cancelled.reason == "task_deleted"
    assert cancelled.task_id == nil and cancelled.run_id == nil
    assert cancelled.finished_at
    refute Repo.get(Task, started.task_id)
    refute Repo.get(Run, started.run_id)
    assert Repo.get!(Record, pending.id) == pending
    assert autopilot_row(view).consecutive_failures == 3

    assert {:ok, {:duplicate, duplicate}} =
             Autopilots.fire_webhook(
               view.id,
               hash,
               "synthetic-delivery",
               "{}",
               "application/json"
             )

    assert duplicate.id == started.id
    assert_enqueued(worker: StartPending, args: %{autopilot_run_id: pending.id})
    assert :ok = perform_job(StartPending, %{autopilot_run_id: pending.id})
    next = Repo.get!(Record, pending.id)
    assert next.status == :started and next.task_id
    assert Repo.get!(Task, next.task_id).description =~ "synthetic pending note"
    assert next.config == pending.config
    assert autopilot_row(view).consecutive_failures == 3
  end

  test "terminal task trigger histories only lose references and keep their outcome", ctx do
    view = autopilot_fixture(ctx.alice_scope)

    histories =
      for status <- [:succeeded, :failed] do
        {:ok, started} = Autopilots.run_now(ctx.alice_scope, view.id)

        Repo.update!(
          Ecto.Changeset.change(started,
            status: status,
            reason: if(status == :failed, do: "synthetic_failure"),
            result: "synthetic result",
            finished_at: DateTime.utc_now()
          )
        )
      end

    Repo.update_all(from(a in Autopilots.Autopilot, where: a.id == ^view.id),
      set: [consecutive_failures: 3]
    )

    assert {:ok, _} = replace(ctx)

    for old <- histories do
      current = Repo.get!(Record, old.id)
      assert current.task_id == nil and current.run_id == nil

      assert Map.take(current, [:status, :reason, :result, :finished_at, :config]) ==
               Map.take(old, [:status, :reason, :result, :finished_at, :config])
    end

    assert autopilot_row(view).consecutive_failures == 3
    refute_enqueued(worker: StartPending)
  end

  test "running taskless autopilot run and trigger record are preserved", ctx do
    task = task_fixture(ctx.alice_scope, ctx.project.key)
    view = autopilot_fixture(ctx.alice_scope, %{mode: "run_only", project: nil})
    {:ok, record} = Autopilots.run_now(ctx.alice_scope, view.id)
    run = Repo.get!(Run, record.run_id)
    run = Repo.update!(Ecto.Changeset.change(run, status: :running))
    assert run.task_id == nil
    assert {:ok, _} = replace(ctx)
    refute Repo.get(Task, task.id)
    assert Repo.get!(Record, record.id) == record
    assert Repo.get!(Run, run.id) == run
    refute_enqueued(worker: StartPending)
  end
end
