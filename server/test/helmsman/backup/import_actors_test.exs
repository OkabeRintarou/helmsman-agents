defmodule Helmsman.Backup.Import.ActorsTest do
  use Helmsman.DataCase, async: false
  import Helmsman.RunsFixtures
  import Helmsman.WorkspacesFixtures
  import Helmsman.ProjectsFixtures
  alias Helmsman.{Actors, Backup, Tasks}
  alias Helmsman.Backup.{Format, ImportRecord}
  alias Helmsman.Backup.Import.Read

  setup do
    ctx = dispatch_fixture()
    target = workspace_fixture(ctx.alice)
    scope = workspace_scope_fixture(ctx.alice, target)
    task_fixture(ctx.alice_scope, ctx.project.key)
    path = Path.join(System.tmp_dir!(), "actor-import-#{System.unique_integer([:positive])}")
    old = Application.get_env(:helmsman, :backup_sandbox)
    Application.put_env(:helmsman, :backup_sandbox, true)

    on_exit(fn ->
      File.rm(path)
      Application.put_env(:helmsman, :backup_sandbox, old)
    end)

    {:ok, _} = Backup.export_to_file(ctx.workspace, path)
    {:ok, data} = Read.file(path)
    Map.merge(ctx, %{target: target, scope: scope, path: path, data: data})
  end

  test "kind collision rolls back; rename rewrites task and history references", ctx do
    name = "ci"

    data =
      ctx.data
      |> Map.update!(
        "actors",
        &(&1 ++ [%{"name" => name, "kind" => "human", "owner" => nil, "disabled" => false}])
      )
      |> Map.update!("tasks", fn rows -> Enum.map(rows, &Map.put(&1, "created_by", name)) end)
      |> Map.update!("task_events", fn rows -> Enum.map(rows, &Map.put(&1, "actor", name)) end)

    File.write!(ctx.path, Format.encode(data))

    existing =
      Repo.insert!(%Actors.Actor{
        workspace_id: ctx.target.id,
        kind: :agent,
        owner_id: ctx.alice.id,
        name: name
      })

    assert {:error, {:actor_kind_conflict, _}} = Backup.import_file(ctx.scope, ctx.path)

    assert Repo.aggregate(from(t in Tasks.Task, where: t.workspace_id == ^ctx.target.id), :count) ==
             0

    assert {:ok, _} = Backup.import_file(ctx.scope, ctx.path, rename: %{name => "historical"})

    actor =
      Repo.one!(
        from(a in Actors.Actor,
          where: a.workspace_id == ^ctx.target.id and a.name == "historical"
        )
      )

    assert actor.kind == :human and is_nil(actor.user_id)
    task = Repo.one!(from(t in Tasks.Task, where: t.workspace_id == ^ctx.target.id))
    assert task.created_by_id == actor.id

    assert Repo.one!(from(e in Tasks.TaskEvent, where: e.task_id == ^task.id)).actor_id ==
             actor.id

    assert Repo.get!(Actors.Actor, existing.id) == existing
  end

  test "existing agent retains owner and configuration; system maps locally", ctx do
    {bob, _} = member_scope_fixture(ctx.target)

    existing =
      Repo.insert!(%Actors.Actor{
        workspace_id: ctx.target.id,
        kind: :agent,
        owner_id: bob.id,
        name: ctx.agent.name,
        disabled_at: DateTime.utc_now(:second)
      })

    assert {:ok, report} = Backup.import_file(ctx.scope, ctx.path)
    assert Repo.get!(Actors.Actor, existing.id) == existing
    assert Enum.any?(report.actors, &(&1.from == ctx.agent.name and &1.action == "existing"))

    assert Repo.aggregate(
             from(a in Actors.Actor,
               where: a.workspace_id == ^ctx.target.id and a.kind == :system
             ),
             :count
           ) == 1
  end

  test "dry run reports new human and disabled external agent without persisting them", ctx do
    data =
      Map.update!(ctx.data, "actors", fn rows ->
        Enum.map(rows, &if(&1["kind"] == "agent", do: Map.put(&1, "disabled", true), else: &1))
      end)

    File.write!(ctx.path, Format.encode(data))

    count =
      Repo.aggregate(from(a in Actors.Actor, where: a.workspace_id == ^ctx.target.id), :count)

    assert {:ok, report} = Backup.import_file(ctx.scope, ctx.path, dry_run: true)
    assert Enum.any?(report.actors, &(&1.from == ctx.agent.name and &1.action == "created"))

    assert Repo.aggregate(
             from(a in Actors.Actor, where: a.workspace_id == ^ctx.target.id),
             :count
           ) == count

    assert Repo.one!(from(i in ImportRecord, where: i.workspace_id == ^ctx.target.id)).dry_run
    assert {:ok, _} = Backup.import_file(ctx.scope, ctx.path)

    actor =
      Repo.one!(
        from(a in Actors.Actor,
          where: a.workspace_id == ^ctx.target.id and a.name == ^ctx.agent.name
        )
      )

    assert actor.owner_id == ctx.alice.id and actor.disabled_at
    refute Repo.exists?(from(p in Helmsman.Agents.AgentProfile, where: p.actor_id == ^actor.id))
  end
end
