defmodule Helmsman.Backup.ConcurrencyTest do
  use ExUnit.Case, async: false
  import Ecto.Query
  import Helmsman.AccountsFixtures
  import Helmsman.WorkspacesFixtures
  import Helmsman.ProjectsFixtures
  alias Helmsman.{Backup, CommittedData, Locks, Repo, Tasks, Tx}
  alias Helmsman.Backup.Import.{Read, Validate}
  alias Helmsman.Backup.Workers.{Import, Prune}

  setup do
    ctx =
      CommittedData.unboxed(fn ->
        user = user_fixture()
        workspace = workspace_fixture(user)
        scope = workspace_scope_fixture(user, workspace)
        project = project_fixture(scope, %{key: "BOS"})
        Repo.update!(Ecto.Changeset.change(project, task_seq: 1))
        task = task_fixture(scope, project.key)
        %{user: user, workspace: workspace, scope: scope, task: task}
      end)

    path =
      Path.join(System.tmp_dir!(), "backup-concurrency-#{System.unique_integer([:positive])}.gz")

    on_exit(fn ->
      File.rm(path)

      CommittedData.unboxed(fn ->
        Repo.delete_all(
          from(i in Backup.ImportRecord, where: i.workspace_id == ^ctx.workspace.id)
        )
      end)

      CommittedData.delete_user_data!([ctx.user.id])
    end)

    Map.put(ctx, :path, path)
  end

  test "export has one consistent read-only snapshot across transition and project creation",
       ctx do
    parent = self()

    exporter =
      Task.async(fn ->
        CommittedData.unboxed(fn ->
          Process.put(:helmsman_test_hook, fn
            {:export_read, "saved_filters"} ->
              assert Repo.query!("SHOW transaction_isolation").rows == [["repeatable read"]]
              assert Repo.query!("SHOW transaction_read_only").rows == [["on"]]
              send(parent, {:paused, self()})

              receive do
                :go -> :ok
              end

            _ ->
              :ok
          end)

          Backup.export_to_file(ctx.workspace, ctx.path)
        end)
      end)

    assert_receive {:paused, pid}, 5000

    CommittedData.unboxed(fn ->
      assert {:ok, _} =
               Tx.run(fn ->
                 {:ok, _} = Tasks.transition(ctx.scope, ctx.task.ident, :in_progress, %{})
                 project = project_fixture(ctx.scope, %{key: "OPS"})
                 {:ok, task_fixture(ctx.scope, project.key)}
               end)
    end)

    send(pid, :go)
    assert {:ok, _} = Task.await(exporter, 10_000)
    {:ok, data} = Read.file(ctx.path)
    assert hd(data["tasks"])["id"] == "BOS-2"
    assert hd(data["tasks"])["status"] == "new"
    assert length(data["task_events"]) == 1
    refute Enum.any?(data["tasks"], &(&1["id"] == "OPS-1"))
    refute Enum.any?(data["task_events"], &(&1["task"] == "OPS-1"))
    assert {:ok, _} = Validate.validate(data)

    assert CommittedData.unboxed(fn -> Repo.get!(Tasks.Task, ctx.task.id).status end) ==
             :in_progress

    assert {:ok, _} =
             CommittedData.unboxed(fn -> Backup.export_to_file(ctx.workspace, ctx.path) end)

    {:ok, next} = Read.file(ctx.path)
    assert Enum.any?(next["tasks"], &(&1["id"] == "OPS-1"))
    assert hd(next["tasks"])["status"] == "in_progress"
    assert {:ok, _} = Validate.validate(next)
  end

  test "maintenance exclusive lock holds ordinary writes and claiming shared probes", ctx do
    parent = self()

    locker =
      Task.async(fn ->
        CommittedData.unboxed(fn ->
          Tx.run(fn ->
            Locks.maint_exclusive!(ctx.workspace.id)
            send(parent, {:locked, self()})

            receive do
              :go -> :ok
            end

            {:ok, :done}
          end)
        end)
      end)

    assert_receive {:locked, pid}, 5000

    assert {:ok, false} =
             CommittedData.unboxed(fn ->
               Tx.run(fn -> {:ok, Locks.try_maint_shared(ctx.workspace.id)} end)
             end)

    writer =
      Task.async(fn ->
        CommittedData.unboxed(fn ->
          Tasks.update(ctx.scope, ctx.task.ident, %{title: "after maintenance"})
        end)
      end)

    refute Task.yield(writer, 100)
    send(pid, :go)
    assert {:ok, :done} = Task.await(locker, 5000)
    assert {:ok, _} = Task.await(writer, 5000)
  end

  test "real import holds the maintenance lock until commit", ctx do
    CommittedData.unboxed(fn -> {:ok, _} = Backup.export_to_file(ctx.workspace, ctx.path) end)
    parent = self()

    importer =
      Task.async(fn ->
        CommittedData.unboxed(fn ->
          Process.put(:helmsman_test_hook, fn
            :import_locked ->
              send(parent, {:import_locked, self()})

              receive do
                :go -> :ok
              end

            _ ->
              :ok
          end)

          Backup.import_file(ctx.scope, ctx.path)
        end)
      end)

    assert_receive {:import_locked, pid}, 5000

    writer =
      Task.async(fn ->
        CommittedData.unboxed(fn ->
          Tasks.update(ctx.scope, ctx.task.ident, %{title: "written after import"})
        end)
      end)

    refute Task.yield(writer, 100)
    send(pid, :go)
    assert {:ok, _} = Task.await(importer, 10_000)
    assert {:ok, _} = Task.await(writer, 5000)
  end

  @tag timeout: 45_000
  test "import returns busy after lock_timeout without writing domain rows", ctx do
    CommittedData.unboxed(fn -> {:ok, _} = Backup.export_to_file(ctx.workspace, ctx.path) end)
    parent = self()

    locker =
      Task.async(fn ->
        CommittedData.unboxed(fn ->
          Tx.run(
            fn ->
              Locks.maint_shared!(ctx.workspace.id)
              send(parent, {:shared_locked, self()})

              receive do
                :go -> :ok
              end

              {:ok, :done}
            end,
            timeout: 45_000
          )
        end)
      end)

    assert_receive {:shared_locked, pid}, 5000

    assert {:error, :busy} =
             CommittedData.unboxed(fn -> Backup.import_file(ctx.scope, ctx.path) end)

    send(pid, :go)
    assert {:ok, :done} = Task.await(locker, 5000)

    assert CommittedData.unboxed(fn -> Repo.get!(Tasks.Task, ctx.task.id).title end) ==
             ctx.task.title
  end

  test "committed import broadcasts one workspace refresh and no row events", ctx do
    CommittedData.unboxed(fn -> {:ok, _} = Backup.export_to_file(ctx.workspace, ctx.path) end)
    flush_mailer()
    Helmsman.Events.subscribe(Helmsman.Events.topic(:workspace, ctx.workspace.id))
    Helmsman.Events.subscribe(Helmsman.Events.topic(:project, ctx.task.project_id))
    Helmsman.Events.subscribe(Helmsman.Events.topic(:task, ctx.task.id))

    assert {:ok, report} =
             CommittedData.unboxed(fn -> Backup.import_file(ctx.scope, ctx.path) end)

    assert report.counts["tasks"].unchanged == 1
    assert_receive {:workspace_imported, _}, 1000
    refute_receive _, 100
  end

  test "workspace import notifications cover queued, running, failed and interrupted", ctx do
    File.write!(ctx.path, "{")
    flush_mailer()
    Helmsman.Events.subscribe(Backup.topic(ctx.workspace.id))

    assert {:ok, record} =
             CommittedData.unboxed(fn -> Backup.start_import(ctx.scope, ctx.path) end)

    id = record.id
    assert_receive {:import, ^id}

    assert :ok =
             CommittedData.unboxed(fn ->
               Import.perform(%Oban.Job{args: %{"id" => id}})
             end)

    assert_receive {:import, ^id}
    assert_receive {:import, ^id}
    assert CommittedData.unboxed(fn -> Repo.get!(Backup.ImportRecord, id).status end) == :failed
    refute_receive {:import, ^id}, 50

    assert {:ok, record} =
             CommittedData.unboxed(fn -> Backup.start_import(ctx.scope, ctx.path) end)

    id = record.id
    assert_receive {:import, ^id}

    assert :ok =
             CommittedData.unboxed(fn ->
               Repo.delete_all(
                 from(j in Oban.Job,
                   where:
                     j.worker == "Helmsman.Backup.Workers.Import" and
                       fragment("(?->>'id')::bigint", j.args) == ^id
                 )
               )

               Prune.perform(%Oban.Job{})
             end)

    assert_receive {:import, ^id}

    assert CommittedData.unboxed(fn -> Repo.get!(Backup.ImportRecord, id).errors end) ==
             [%{"reason" => "interrupted"}]
  end

  defp flush_mailer do
    receive do
      {:email, _} -> flush_mailer()
    after
      0 -> :ok
    end
  end
end
