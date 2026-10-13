defmodule HelmsmanWeb.SettingsLive.DataExportTest do
  @moduledoc """
  Spec web-data-settings with real exports (add-data-settings-ui 6.2): exporting reads in
  a `REPEATABLE READ` transaction, which the SQL sandbox only allows with the global
  `:backup_sandbox` flag (as in the domain's export tests), hence `async: false`.
  """
  use HelmsmanWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest
  import HelmsmanWeb.PortalHelpers
  import Helmsman.AccountsFixtures
  import Helmsman.WorkspacesFixtures

  alias Helmsman.{Actors, Backup, Repo}
  alias Helmsman.Backup.{ExportRecord, Files, ImportRecord}
  alias Helmsman.Backup.Workers.Export, as: ExportWorker
  alias Helmsman.Backup.Workers.Import, as: ImportWorker
  alias HelmsmanWeb.SettingsLive.Data

  setup do
    old = Application.get_env(:helmsman, :backup_sandbox)
    Application.put_env(:helmsman, :backup_sandbox, true)
    on_exit(fn -> Application.put_env(:helmsman, :backup_sandbox, old) end)
  end

  setup %{conn: conn} do
    _admin = user_fixture()
    owner = user_fixture(%{display_name: "olivia"})
    ws = workspace_fixture(owner, %{name: "Acme"})
    users = %{owner: owner}

    users =
      for {role, name} <- [admin: "alice", member: "bob", member2: "carol", viewer: "dave"],
          into: users do
        user = user_fixture(%{display_name: name})
        member_fixture(ws, user, if(role == :member2, do: :member, else: role))
        {role, user}
      end

    on_exit(fn -> File.rm_rf(Files.directory(:imports) |> Path.join("#{ws.id}-*")) end)
    %{conn: conn, ws: ws, users: users, path: "/w/#{ws.slug}/settings/data"}
  end

  defp open(ctx, role, query \\ ""),
    do: live(log_in_user(ctx.conn, ctx.users[role]), ctx.path <> query)

  defp scope(ctx, role), do: workspace_scope_fixture(ctx.users[role], ctx.ws)
  defp row(name), do: "#unclaimed-#{Data.dom_key(name)}"

  defp imports(ctx),
    do: Repo.all(from(i in ImportRecord, where: i.workspace_id == ^ctx.ws.id, order_by: i.id))

  defp staged_path(view), do: :sys.get_state(view.pid).socket.assigns.staged.path

  defp upload(view, name, content) do
    file =
      file_input(view, "#import-upload-form", :import_file, [
        %{name: name, content: content, type: "application/gzip"}
      ])

    render_upload(file, name)
  end

  defp panel?(view, selector, text \\ nil), do: in_portal?(view, "import-panel", selector, text)

  test "exporting and downloading", ctx do
    {:ok, view, _html} = open(ctx, :admin)
    view |> element("#export-button") |> render_click()

    assert render(view) =~ "已开始导出"
    [export] = Repo.all(from(e in ExportRecord, where: e.workspace_id == ^ctx.ws.id))
    assert has_element?(view, "#export-#{export.id}", "排队中")

    assert :ok = ExportWorker.perform(%Oban.Job{args: %{"id" => export.id}})

    assert has_element?(view, "#export-#{export.id}", "可下载")
    assert has_element?(view, "#export-#{export.id}", "身份")
    assert has_element?(view, "#export-#{export.id}", "24 小时后过期")

    href = "/w/#{ctx.ws.slug}/exports/#{export.id}/download"
    assert has_element?(view, ~s(#export-#{export.id}-download[href="#{href}"]))

    conn = get(log_in_user(build_conn(), ctx.users[:admin]), href)
    assert conn.status == 200
    assert get_resp_header(conn, "content-type") |> hd() =~ "application/gzip"
  end

  test "merge import of a real export file", ctx do
    source_owner = user_fixture(%{display_name: "zed"})
    source = workspace_fixture(source_owner, %{name: "Source"})
    zed = workspace_scope_fixture(source_owner, source).actor.name
    path = Path.join(System.tmp_dir!(), "hm-data-test-#{System.unique_integer([:positive])}")

    :ok =
      Backup.export_to_file(source, path) |> then(&if(match?({:ok, _}, &1), do: :ok, else: &1))

    on_exit(fn -> File.rm(path) end)

    {:ok, view, _html} = open(ctx, :admin, "?panel=import")
    upload(view, "source.helmsman.json.gz", File.read!(path))
    render_submit(view, "dry_run", %{})

    assert panel?(view, "#import-dry-running")
    assert panel?(view, "#import-form fieldset[disabled]")
    [dry] = imports(ctx)
    assert dry.dry_run and dry.file_name == "source.helmsman.json.gz"
    staged = staged_path(view)
    assert File.exists?(staged)

    assert :ok = ImportWorker.perform(%Oban.Job{args: %{"id" => dry.id}})
    assert panel?(view, "#import-preview-report-actors", zed)
    assert panel?(view, "#import-preview-report-actors", "新建为未认领")
    refute Enum.any?(Actors.list(scope(ctx, :owner)) |> elem(1), &(&1.name == zed))

    render_click(view, "confirm_import", %{})
    [^dry, real] = Enum.map(imports(ctx), &if(&1.id == dry.id, do: dry, else: &1))
    refute real.dry_run
    assert Map.delete(real.options, "dry_run") == Map.delete(dry.options, "dry_run")
    assert real.file_name == dry.file_name

    assert :ok = ImportWorker.perform(%Oban.Job{args: %{"id" => real.id}})

    assert Repo.get!(ImportRecord, real.id).file_sha256 ==
             Repo.get!(ImportRecord, dry.id).file_sha256

    assert_patch(view, ctx.path)
    assert render(view) =~ "导入完成"
    assert has_element?(view, "#imports li:first-child#import-#{real.id}")
    assert has_element?(view, row(zed))
    refute has_element?(view, "#hm-import-notice")
    refute File.exists?(staged)
  end
end
