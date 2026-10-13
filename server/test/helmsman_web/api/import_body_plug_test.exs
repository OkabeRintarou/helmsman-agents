defmodule HelmsmanWeb.API.ImportBodyPlugTest do
  use HelmsmanWeb.ConnCase, async: false
  import Helmsman.ProjectsFixtures
  import Helmsman.AgentsFixtures
  import Helmsman.ApiTokensFixtures
  import HelmsmanWeb.APIHelpers
  import OpenApiSpex.TestAssertions
  alias Helmsman.{Backup, Repo}
  alias Helmsman.Backup.{Files, ImportRecord}
  alias Helmsman.Backup.Workers.Import
  alias HelmsmanWeb.{Endpoint, ImportBodyAdapter}

  setup do
    ctx = api_fixture()
    dir = Path.join(System.tmp_dir!(), "rest-import-#{System.unique_integer([:positive])}")
    old_dir = Application.fetch_env!(:helmsman, :data_dir)
    old_sandbox = Application.get_env(:helmsman, :backup_sandbox)
    old_limit = Application.fetch_env!(:helmsman, :import_max_bytes)
    old_rate = Application.get_env(:helmsman, :api_token_rate_limit)
    Application.put_env(:helmsman, :data_dir, dir)
    Application.put_env(:helmsman, :backup_sandbox, true)

    on_exit(fn ->
      Application.put_env(:helmsman, :data_dir, old_dir)
      Application.put_env(:helmsman, :backup_sandbox, old_sandbox)
      Application.put_env(:helmsman, :import_max_bytes, old_limit)
      Application.put_env(:helmsman, :api_token_rate_limit, old_rate)
      File.rm_rf(dir)
    end)

    project = project_fixture(ctx.scope)
    task_fixture(ctx.scope, project.key)
    path = Path.join(dir, "source.gz")
    :ok = Files.ready()
    {:ok, _} = Backup.export_to_file(ctx.workspace, path)
    gzip = File.read!(path)
    File.rm!(path)
    Map.merge(ctx, %{json: :zlib.gunzip(gzip), gzip: gzip, dir: dir})
  end

  defp request(ctx, token, query \\ "", headers \\ [], body \\ "", chunks \\ nil) do
    ref = make_ref()
    conn = Plug.Test.conn(:post, w(ctx.slug, "/imports") <> query, body)
    conn = if token, do: put_req_header(conn, "authorization", "Bearer " <> token), else: conn
    conn = Enum.reduce(headers, conn, fn {k, v}, conn -> put_req_header(conn, k, v) end)
    {_, state} = conn.adapter
    state = state |> Map.put(:upload_ref, ref) |> Map.put(:upload_chunks, chunks)
    conn = Endpoint.call(%{conn | adapter: {ImportBodyAdapter, state}}, Endpoint.init([]))
    {conn, ref}
  end

  defp reject(ctx, token, query, headers, status, code) do
    {conn, ref} = request(ctx, token, query, headers)
    error!(conn, status, code)
    refute_received {:upload_read, ^ref}
    assert File.ls!(Files.directory(:imports)) == []
    assert Repo.aggregate(ImportRecord, :count) == 0
    conn
  end

  test "authentication, scope, tenant, identity and role denials never read the body", ctx do
    reject(ctx, nil, "", [], 401, "unauthorized")
    reject(ctx, "hmr_redacted", "", [], 401, "unauthorized")
    read_only = token_for(ctx.alice, ctx.workspace, %{scopes: ["api:read"]})
    reject(ctx, read_only, "", [], 403, "insufficient_scope")
    reject(%{ctx | slug: "other-workspace"}, ctx.token, "", [], 404, "not_found")
    {_user, viewer} = member_token(ctx.workspace, :viewer)
    reject(ctx, viewer, "", [], 403, "forbidden")
    {_user, member} = member_token(ctx.workspace, :member)
    reject(ctx, member, "", [], 403, "forbidden")
    agent = managed_agent_fixture(ctx.scope)
    reject(ctx, ctx.token, "", [{"x-helmsman-actor", agent.name}], 403, "forbidden")
    assert Repo.aggregate(ImportRecord, :count) == 0
  end

  test "query, confirmation, storage and media checks happen before reads", ctx do
    for query <- [
          "?mode=bad",
          "?rename[old]=bad%20name",
          "?rename[old]=helmsman",
          "?rename[old]=%FF",
          "?dry_run=1",
          "?source=other",
          "?rename[]=x",
          "?rename[old][nested]=x"
        ] do
      reject(ctx, ctx.token, query, [], 400, "invalid_params")
    end

    reject(ctx, ctx.token, "?mode=replace", [], 422, "confirmation_required")
    {_user, admin} = member_token(ctx.workspace, :admin)
    reject(ctx, admin, "?mode=replace&confirm=#{ctx.slug}", [], 403, "forbidden")

    for headers <- [
          [],
          [{"content-type", "text/plain"}],
          [{"content-type", "application/json"}, {"content-length", "abc"}]
        ] do
      {status, code} =
        if List.keymember?(headers, "content-length", 0),
          do: {400, "invalid_params"},
          else: {415, "unsupported_media_type"}

      reject(ctx, ctx.token, "", headers, status, code)
    end

    File.chmod!(ctx.dir, 0o500)
    reject(ctx, ctx.token, "", [{"content-type", "application/json"}], 503, "storage_unavailable")
    File.chmod!(ctx.dir, 0o700)
  end

  test "rate limit and busy denials do not consume any upload bytes", ctx do
    Application.put_env(:helmsman, :api_token_rate_limit, 1)
    token = token_for(ctx.alice, ctx.workspace)
    token |> api_get(w(ctx.slug, "/me")) |> body!(200)
    reject(ctx, token, "", [], 429, "rate_limited")
    Application.put_env(:helmsman, :api_token_rate_limit, 600)
    path = Path.join(ctx.dir, "queued.json")
    File.write!(path, ctx.json)
    {:ok, record} = Backup.start_import(ctx.scope, path)
    {conn, ref} = request(ctx, ctx.token)
    error!(conn, 409, "busy")
    refute_received {:upload_read, ^ref}
    assert File.ls!(Files.directory(:imports)) == [record.upload]
    assert Repo.aggregate(ImportRecord, :count) == 1
  end

  test "JSON and gzip uploads return 202, execute asynchronously and spend one quota", ctx do
    Application.put_env(:helmsman, :api_token_rate_limit, 5)

    for {body, type} <- [{ctx.json, "application/json"}, {ctx.gzip, "application/gzip"}] do
      token = token_for(ctx.alice, ctx.workspace)
      {conn, ref} = request(ctx, token, "?dry_run=true", [{"content-type", type}], body)
      assert conn.halted
      assert_received {:upload_read, ^ref}
      assert get_resp_header(conn, "x-ratelimit-remaining") == ["4"]
      result = body!(conn, 202)["data"]
      assert_schema(result, "ImportRecord", api_spec())
      refute Map.has_key?(result, "upload")
      refute Map.has_key?(result, "options")
      assert result["status"] == "queued"
      assert File.ls!(Files.directory(:imports)) == [Repo.get!(ImportRecord, result["id"]).upload]
      assert :ok = Import.perform(%Oban.Job{args: %{"id" => result["id"]}})
      status = token |> api_get(w(ctx.slug, "/imports/#{result["id"]}")) |> body!(200)
      assert status["data"]["status"] == "succeeded"
      assert File.ls!(Files.directory(:imports)) == []
      assert get_resp_header(api_get(token, w(ctx.slug, "/me")), "x-ratelimit-remaining") == ["2"]
    end
  end

  test "default agent is ignored and own human header works; Agent header is forbidden", ctx do
    agent = managed_agent_fixture(ctx.scope)
    %{token: token} = api_token_fixture(ctx.scope, %{default_agent_id: agent.actor_id})
    reject(ctx, token, "", [{"x-helmsman-actor", agent.name}], 403, "forbidden")

    for headers <- [[], [{"x-helmsman-actor", ctx.scope.actor.name}]] do
      {conn, _ref} =
        request(
          ctx,
          token,
          "?dry_run=true",
          [{"content-type", "application/json"} | headers],
          ctx.json
        )

      id = body!(conn, 202)["data"]["id"]
      assert Repo.get!(ImportRecord, id).user_id == ctx.alice.id
      assert :ok = Import.perform(%Oban.Job{args: %{"id" => id}})
    end
  end

  test "known length rejects without reads; chunked overflow and interruption remove partial files",
       ctx do
    Application.put_env(:helmsman, :import_max_bytes, 10)

    reject(
      ctx,
      ctx.token,
      "",
      [{"content-type", "application/json"}, {"content-length", "11"}],
      413,
      "too_large"
    )

    for {chunks, status, code} <- [
          {[{:more, "12345678"}, {:ok, "901"}], 413, "too_large"},
          {[{:more, "123"}, :error], 400, "invalid_params"}
        ] do
      {conn, ref} =
        request(ctx, ctx.token, "", [{"content-type", "application/json"}], "", chunks)

      error!(conn, status, code)
      assert_received {:upload_read, ^ref}
      assert File.ls!(Files.directory(:imports)) == []
      assert Repo.aggregate(ImportRecord, :count) == 0
    end
  end

  test "bosun and rename query options reach the queued import", ctx do
    body = File.read!(Path.expand("../../fixtures/bosun/export-v2.json", __DIR__))

    {conn, _ref} =
      request(
        ctx,
        ctx.token,
        "?source=bosun&rename[user]=renamed&dry_run=true",
        [{"content-type", "application/json"}],
        body
      )

    id = body!(conn, 202)["data"]["id"]
    record = Repo.get!(ImportRecord, id)
    assert record.source == :bosun
    assert record.options["rename"] == %{"user" => "renamed"}
    assert :ok = Import.perform(%Oban.Job{args: %{"id" => id}})
    assert Repo.get!(ImportRecord, id).status == :succeeded
  end

  test "owner replace and admin merge use the same asynchronous import path", ctx do
    {_user, admin} = member_token(ctx.workspace, :admin)

    for {token, query} <- [
          {ctx.token, "?mode=replace&confirm=#{ctx.slug}"},
          {admin, "?mode=merge"}
        ] do
      {conn, _ref} = request(ctx, token, query, [{"content-type", "application/gzip"}], ctx.gzip)
      result = body!(conn, 202)["data"]
      assert :ok = Import.perform(%Oban.Job{args: %{"id" => result["id"]}})
      assert Repo.get!(ImportRecord, result["id"]).status == :succeeded
    end
  end

  test "file validation failure is retained in the asynchronous REST audit", ctx do
    {conn, _ref} = request(ctx, ctx.token, "", [{"content-type", "application/json"}], "{")
    id = body!(conn, 202)["data"]["id"]
    assert :ok = Import.perform(%Oban.Job{args: %{"id" => id}})
    result = ctx.token |> api_get(w(ctx.slug, "/imports/#{id}")) |> body!(200)
    assert_schema(result["data"], "ImportRecord", api_spec())
    assert result["data"]["status"] == "failed"
    assert length(result["data"]["errors"]) == 1
    assert File.ls!(Files.directory(:imports)) == []
  end

  test "body larger than ordinary JSON parser limit is streamed by the endpoint", ctx do
    body = String.duplicate(" ", 8_100_000) <> ctx.json

    {conn, _ref} =
      request(ctx, ctx.token, "?dry_run=true", [{"content-type", "application/json"}], body)

    id = body!(conn, 202)["data"]["id"]
    assert :ok = Import.perform(%Oban.Job{args: %{"id" => id}})
    assert Repo.get!(ImportRecord, id).status == :succeeded
    assert File.ls!(Files.directory(:imports)) == []
  end

  test "upload operation documents raw bodies, parameters, errors and human identity", _ctx do
    operation = api_spec().paths["/api/v1/w/{slug}/imports"].post

    assert Map.keys(operation.requestBody.content) |> Enum.sort() == [
             "application/gzip",
             "application/json"
           ]

    assert operation.requestBody.required
    assert Enum.any?(operation.parameters, &(&1.name == :confirm))
    header = Enum.find(operation.parameters, &(&1.name == :"X-Helmsman-Actor"))
    assert header.description =~ "human identity"
    assert Map.has_key?(operation.responses, 503)
  end
end
