defmodule HelmsmanWeb.API.BackupControllerTest do
  use HelmsmanWeb.ConnCase, async: false
  import Helmsman.ProjectsFixtures
  import Helmsman.AgentsFixtures
  import Helmsman.ApiTokensFixtures
  import HelmsmanWeb.APIHelpers
  import OpenApiSpex.TestAssertions
  alias Helmsman.{Backup, Repo}
  alias Helmsman.Backup.{ExportRecord, Files, ImportRecord}
  alias Helmsman.Backup.Workers.Export

  setup do
    ctx = api_fixture()
    dir = Path.join(System.tmp_dir!(), "rest-export-#{System.unique_integer([:positive])}")
    old_dir = Application.fetch_env!(:helmsman, :data_dir)
    old_sandbox = Application.get_env(:helmsman, :backup_sandbox)
    Application.put_env(:helmsman, :data_dir, dir)
    Application.put_env(:helmsman, :backup_sandbox, true)

    on_exit(fn ->
      Application.put_env(:helmsman, :data_dir, old_dir)
      Application.put_env(:helmsman, :backup_sandbox, old_sandbox)
      File.rm_rf(dir)
    end)

    project = project_fixture(ctx.scope)
    task_fixture(ctx.scope, project.key)
    ctx
  end

  test "request, poll and gzip attachment only expose safe job fields", ctx do
    body = api_send(:post, ctx.token, w(ctx.slug, "/exports")) |> body!(202)
    assert_schema(body["data"], "ExportRecord", api_spec())
    id = body["data"]["id"]
    assert body["data"]["status"] == "queued"
    refute Map.has_key?(body["data"], "file")
    coalesced = api_send(:post, ctx.token, w(ctx.slug, "/exports")) |> body!(202)
    assert coalesced["data"]["id"] == id
    assert :ok = Export.perform(%Oban.Job{args: %{"id" => id}})
    result = api_get(ctx.token, w(ctx.slug, "/exports/#{id}")) |> body!(200)
    assert_schema(result["data"], "ExportRecord", api_spec())
    assert result["data"]["status"] == "succeeded"

    conn =
      api_get(ctx.token, w(ctx.slug, "/exports/#{id}/download"), [{"accept", "application/gzip"}])

    assert conn.status == 200
    assert get_resp_header(conn, "content-type") == ["application/gzip"]
    assert hd(get_resp_header(conn, "content-disposition")) =~ ".helmsman.json.gz"
    assert Jason.decode!(:zlib.gunzip(conn.resp_body))["format"] == "helmsman-export"
  end

  test "admin imports visible across initiators, exports private and tenant scoped", ctx do
    {:ok, exported} = Backup.request_export(ctx.scope)
    assert :ok = Export.perform(%Oban.Job{args: %{"id" => exported.id}})
    {:ok, path} = Files.path(:exports, Repo.get!(ExportRecord, exported.id).file)
    {:ok, imported} = Backup.start_import(ctx.scope, path)
    {_user, admin} = member_token(ctx.workspace, :admin)
    admin |> api_get(w(ctx.slug, "/imports/#{imported.id}")) |> body!(200)

    for suffix <- ["", "/download"] do
      admin
      |> api_get(w(ctx.slug, "/exports/#{exported.id}#{suffix}"))
      |> error!(404, "not_found")
    end

    {_user, viewer} = member_token(ctx.workspace, :viewer)
    viewer |> api_get(w(ctx.slug, "/imports/#{imported.id}")) |> error!(403, "forbidden")
    ctx.token |> api_get(w("another", "/imports/#{imported.id}")) |> error!(404, "not_found")

    ctx.token
    |> api_get(w("another", "/exports/#{exported.id}/download"))
    |> error!(404, "not_found")

    for id <- ["0", "abc", "999999999"] do
      ctx.token |> api_get(w(ctx.slug, "/imports/#{id}")) |> error!(404, "not_found")
    end

    assert Repo.get!(ImportRecord, imported.id).status == :queued
  end

  test "expired or failed artifacts cannot be downloaded", ctx do
    {:ok, record} = Backup.request_export(ctx.scope)

    ctx.token
    |> api_get(w(ctx.slug, "/exports/#{record.id}/download"))
    |> error!(404, "not_found")

    assert :ok = Export.perform(%Oban.Job{args: %{"id" => record.id}})

    Repo.update!(
      Ecto.Changeset.change(Repo.get!(ExportRecord, record.id),
        expires_at: DateTime.add(Backup.now(), -1)
      )
    )

    ctx.token
    |> api_get(w(ctx.slug, "/exports/#{record.id}/download"))
    |> error!(404, "not_found")
  end

  test "exports ignore default Agent but reject requested Agent and nonadmins", ctx do
    agent = managed_agent_fixture(ctx.scope)
    %{token: token} = api_token_fixture(ctx.scope, %{default_agent_id: agent.actor_id})

    api_send(:post, token, w(ctx.slug, "/exports"), nil, [{"x-helmsman-actor", agent.name}])
    |> error!(403, "forbidden")

    assert Repo.aggregate(ExportRecord, :count) == 0

    for headers <- [[], [{"x-helmsman-actor", ctx.scope.actor.name}]] do
      assert api_send(:post, token, w(ctx.slug, "/exports"), nil, headers) |> body!(202)
    end

    {_user, member} = member_token(ctx.workspace, :member)
    api_send(:post, member, w(ctx.slug, "/exports")) |> error!(403, "forbidden")
    read_only = token_for(ctx.alice, ctx.workspace, %{scopes: ["api:read"]})
    api_send(:post, read_only, w(ctx.slug, "/exports")) |> error!(403, "insufficient_scope")
  end
end
