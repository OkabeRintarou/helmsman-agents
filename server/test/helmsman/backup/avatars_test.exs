defmodule Helmsman.Backup.AvatarsTest do
  # add-actor-avatars 7.4: actor-avatars「头像与导出导入」and
  # workspace-export「不导出头像」(decision 14).
  use Helmsman.DataCase, async: false

  import Helmsman.AvatarsFixtures
  import Helmsman.SquadsFixtures
  import Helmsman.WorkspacesFixtures

  alias Helmsman.{Actors, Avatars, Backup}
  alias Helmsman.Avatars.Avatar
  alias Helmsman.Backup.Format
  alias Helmsman.Backup.Import.Read

  setup do
    old = Application.get_env(:helmsman, :backup_sandbox)
    Application.put_env(:helmsman, :backup_sandbox, true)
    on_exit(fn -> Application.put_env(:helmsman, :backup_sandbox, old) end)
    ctx = squads_fixture()

    paths =
      Enum.map(1..2, fn n ->
        Path.join(System.tmp_dir!(), "avatars-#{System.unique_integer([:positive])}-#{n}.gz")
      end)

    on_exit(fn -> Enum.each(paths, &File.rm/1) end)

    keys =
      for {target, data} <- [
            {:me, png(64, 64)},
            {{:actor, "keel/dev"}, webp(64, 64)},
            {{:actor, "web-team"}, jpeg(64, 64)}
          ],
          into: %{} do
        {:ok, %{key: key}} = Avatars.put(ctx.alice_scope, target, data)
        {target, key}
      end

    Map.merge(ctx, %{paths: paths, keys: keys})
  end

  defp avatars,
    do: Repo.all(from(a in Avatar, order_by: a.id, select: {a.id, a.key, a.updated_at}))

  test "the export has no avatar bytes, address or key, and is as without avatars", ctx do
    [with, without] = ctx.paths
    {:ok, _} = Backup.export_to_file(ctx.workspace, with)
    json = with |> File.read!() |> :zlib.gunzip()

    refute json =~ "avatar"

    for {_target, key} <- ctx.keys do
      refute json =~ key
    end

    Repo.delete_all(Avatar)
    {:ok, _} = Backup.export_to_file(ctx.workspace, without)
    {:ok, a} = Read.file(with)
    {:ok, b} = Read.file(without)
    assert a["version"] == 2

    assert Format.encode(Map.delete(a, "exported_at")) ==
             Format.encode(Map.delete(b, "exported_at"))
  end

  test "replace (dry run and real) and merge leave every avatar as it was", ctx do
    [path, _] = ctx.paths
    {:ok, _} = Backup.export_to_file(ctx.workspace, path)
    before = avatars()
    slug = ctx.workspace.slug

    assert {:ok, _} =
             Backup.import_file(ctx.alice_scope, path,
               mode: :replace,
               confirm: slug,
               dry_run: true
             )

    assert {:ok, _} = Backup.import_file(ctx.alice_scope, path, mode: :replace, confirm: slug)
    assert {:ok, _} = Backup.import_file(ctx.alice_scope, path)
    assert {:ok, _} = Backup.import_file(ctx.alice_scope, path, dry_run: true)

    assert avatars() == before
    appearance = Actors.appearance(ctx.alice_scope)
    assert appearance["keel/dev"].avatar_key == ctx.keys[{:actor, "keel/dev"}]
    assert appearance["web-team"].avatar_key == ctx.keys[{:actor, "web-team"}]
    assert appearance[ctx.alice_scope.actor.name].avatar_key == ctx.keys[:me]
  end

  test "agents and squads created by an import have no avatar", ctx do
    [path, _] = ctx.paths
    {:ok, _} = Backup.export_to_file(ctx.workspace, path)
    target = workspace_fixture(ctx.alice)
    scope = workspace_scope_fixture(ctx.alice, target)
    before = avatars()

    assert {:ok, _} = Backup.import_file(scope, path)

    assert avatars() == before
    appearance = Actors.appearance(scope)
    assert %{kind: :agent, avatar_key: nil} = appearance["keel/dev"]
    assert %{kind: :squad, avatar_key: nil} = appearance["web-team"]
    # The user's own avatar shows on her identity there, as everywhere.
    assert appearance[scope.actor.name].avatar_key == ctx.keys[:me]
  end
end
