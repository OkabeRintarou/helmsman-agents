defmodule HelmsmanWeb.ExportControllerTest do
  use HelmsmanWeb.ConnCase, async: false
  import Helmsman.WorkspacesFixtures
  import Helmsman.RunsFixtures
  alias Helmsman.Backup
  alias Helmsman.Backup.Workers.Export
  setup :register_and_log_in_user

  setup %{user: user} do
    workspace = workspace_fixture(user)
    scope = workspace_scope_fixture(user, workspace)
    old = Application.get_env(:helmsman, :backup_sandbox)
    Application.put_env(:helmsman, :backup_sandbox, true)
    on_exit(fn -> Application.put_env(:helmsman, :backup_sandbox, old) end)
    {:ok, record} = Backup.request_export(scope)
    :ok = Export.perform(%Oban.Job{args: %{"id" => record.id}})
    {:ok, file} = Backup.export_file(scope, record.id)
    on_exit(fn -> File.rm(file.path) end)
    %{record: record, workspace: workspace, scope: scope}
  end

  test "requester downloads a gzip attachment", ctx do
    conn = get(ctx.conn, "/w/#{ctx.workspace.slug}/exports/#{ctx.record.id}/download")
    assert response(conn, 200) |> binary_part(0, 2) == <<31, 139>>
    assert get_resp_header(conn, "content-type") |> hd() =~ "application/gzip"
    assert get_resp_header(conn, "content-disposition") |> hd() =~ ".helmsman.json.gz"
  end

  test "other admins and members cannot download another person's export", ctx do
    for role <- [:admin, :member] do
      {user, _} = member_scope_fixture(ctx.workspace, role)

      conn =
        build_conn()
        |> log_in_user(user)
        |> get("/w/#{ctx.workspace.slug}/exports/#{ctx.record.id}/download")

      assert response(conn, 404)
    end
  end

  test "expired or failed exports cannot be downloaded", ctx do
    old = Application.get_env(:helmsman, :backup_clock)

    Application.put_env(:helmsman, :backup_clock, fn ->
      DateTime.add(DateTime.utc_now(), 25 * 60 * 60)
    end)

    on_exit(fn -> Application.put_env(:helmsman, :backup_clock, old) end)

    assert response(
             get(ctx.conn, "/w/#{ctx.workspace.slug}/exports/#{ctx.record.id}/download"),
             404
           )
  end

  test "failed and queued jobs look absent", ctx do
    for status <- [:failed, :queued] do
      Helmsman.Repo.update!(Ecto.Changeset.change(ctx.record, status: status))

      assert response(
               get(ctx.conn, "/w/#{ctx.workspace.slug}/exports/#{ctx.record.id}/download"),
               404
             )
    end
  end
end
