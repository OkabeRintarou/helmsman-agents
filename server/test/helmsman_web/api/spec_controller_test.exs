defmodule HelmsmanWeb.API.SpecControllerTest do
  # add-spec-workflow 3.3: rest-api 「规格端点」 (decision 21).
  use HelmsmanWeb.ConnCase, async: true

  import Helmsman.ApiTokensFixtures
  import Helmsman.RunsFixtures
  import Helmsman.TaskSpecsFixtures
  import HelmsmanWeb.APIHelpers
  import OpenApiSpex.TestAssertions

  alias Helmsman.TaskSpecs
  alias HelmsmanWeb.{Endpoint, ImportBodyAdapter}

  setup do
    ctx = specs_fixture()
    %{token: token} = api_token_fixture(ctx.alice_scope)
    agent_fixture(ctx.workspace, ctx.alice, "alice/cli")

    Map.merge(ctx, %{
      token: token,
      slug: ctx.workspace.slug,
      ident: ctx.task.ident,
      spec: api_spec()
    })
  end

  defp spec_path(ctx, rest \\ ""), do: w(ctx.slug, "/tasks/#{ctx.ident}/spec#{rest}")

  defp propose(ctx, version) do
    {lead, _run} = agent_run_scope(ctx.lead, ctx.task, %{squad_id: ctx.squad.id})

    {:ok, %{decision: :proposed}} =
      TaskSpecs.finalize(lead, ctx.ident, %{version: version, summary: "Settled."})
  end

  defp tar_gz(files) do
    {:ok, fd} = :file.open("", [:ram, :read, :write, :binary])
    {:ok, tar} = :erl_tar.init(fd, :write, &ram/2)
    for {name, content} <- files, do: :ok = :erl_tar.add(tar, content, ~c"#{name}", [])
    :ok = :erl_tar.close(tar)
    {:ok, size} = :file.position(fd, :cur)
    {:ok, data} = :file.pread(fd, 0, size)
    :zlib.gzip(data)
  end

  defp ram(:write, {fd, data}), do: :file.write(fd, data)
  defp ram(:position, {fd, position}), do: :file.position(fd, position)
  defp ram(:close, _fd), do: :ok

  defp change_archive(prefix, files \\ spec_files()),
    do: tar_gz(for {path, content} <- files, do: {prefix <> path, content})

  # A POST to the import endpoint through the endpoint with an adapter that
  # reports every body read.
  defp import(ctx, token, query, headers, body) do
    ref = make_ref()
    conn = Plug.Test.conn(:post, spec_path(ctx, "/import") <> query, body)
    conn = if token, do: put_req_header(conn, "authorization", "Bearer " <> token), else: conn
    conn = Enum.reduce(headers, conn, fn {k, v}, conn -> put_req_header(conn, k, v) end)
    {_, state} = conn.adapter
    state = state |> Map.put(:upload_ref, ref) |> Map.put(:upload_chunks, nil)
    conn = Endpoint.call(%{conn | adapter: {ImportBodyAdapter, state}}, Endpoint.init([]))
    {conn, ref}
  end

  @gzip [{"content-type", "application/gzip"}]

  test "a person approves over REST", ctx do
    spec_fixture(ctx.alice_scope, ctx.ident, versions: 3)
    propose(ctx, 3)

    data = api_send(:post, ctx.token, spec_path(ctx, "/finalize"), %{version: 3}) |> body!(200)
    assert %{"status" => "finalized", "decision" => "approved"} = data["data"]
    assert_schema(data["data"], "SpecDecision", ctx.spec)
  end

  test "an agent identity only proposes and cannot reject", ctx do
    spec_fixture(ctx.alice_scope, ctx.ident)
    {:ok, _} = Helmsman.Tasks.update(ctx.alice_scope, ctx.ident, %{assignee: "alice/cli"})
    agent = [{"x-helmsman-actor", "alice/cli"}]

    data =
      api_send(
        :post,
        ctx.token,
        spec_path(ctx, "/finalize"),
        %{version: 1, summary: "Done."},
        agent
      )
      |> body!(200)

    assert %{"status" => "pending_approval", "decision" => "proposed"} = data["data"]

    api_send(:post, ctx.token, spec_path(ctx, "/reject"), %{reason: "No."}, agent)
    |> error!(403, "forbidden")

    data =
      api_send(:post, ctx.token, spec_path(ctx, "/reject"), %{reason: "Not yet.", wake: false})
      |> body!(200)

    assert %{"spec" => %{"status" => "draft", "proposal" => nil}, "dispatch" => nil} =
             data["data"]

    api_send(:post, ctx.token, spec_path(ctx, "/reject"), %{reason: "Again."})
    |> error!(409, "no_proposal")

    api_send(:post, ctx.token, spec_path(ctx, "/reject"), %{wake: false})
    |> error!(400, "invalid_params")
  end

  test "reads: spec, diff, reviews, events and /me/specs", ctx do
    api_get(ctx.token, spec_path(ctx)) |> error!(404, "spec_not_found")
    spec_fixture(ctx.alice_scope, ctx.ident, versions: 2)
    propose(ctx, 2)

    data = api_get(ctx.token, spec_path(ctx) <> "?version=1&files[]=proposal.md") |> body!(200)
    assert_schema(data["data"], "SpecDetail", ctx.spec)
    files = data["data"]["version"]["files"]
    assert [%{"path" => "proposal.md"}] = Enum.filter(files, & &1["content"])

    data = api_get(ctx.token, spec_path(ctx, "/diff?from=1&to=2")) |> body!(200)
    assert_schema(data["data"], "SpecDiff", ctx.spec)
    assert data["data"]["files"] |> hd() |> Map.fetch!("diff") =~ "@@"

    data = api_get(ctx.token, spec_path(ctx, "/reviews")) |> body!(200)
    assert_schema(data["data"], "SpecReviews", ctx.spec)

    data = api_get(ctx.token, spec_path(ctx, "/events")) |> body!(200)
    assert_schema(data["data"], "SpecEvents", ctx.spec)
    assert Enum.map(data["data"], & &1["action"]) == ~w(created version_submitted
                                                        version_submitted finalize_proposed)

    data = api_get(ctx.token, w(ctx.slug, "/me/specs")) |> body!(200)
    assert_schema(data["data"], "SpecAttention", ctx.spec)
    assert [%{"task" => ident, "version" => 2}] = data["data"]["pending_approval"]
    assert ident == ctx.ident

    data = api_get(ctx.token, w(ctx.slug, "/tasks/#{ctx.ident}")) |> body!(200)
    assert %{"status" => "pending_approval", "latest_version" => 2} = data["data"]["spec"]
    assert_schema(data["data"], "TaskDetail", ctx.spec)
  end

  test "writes: create, versions, reviews, notes, ruling, requests", ctx do
    data = api_send(:patch, ctx.token, spec_path(ctx), %{change_id: "add-x"}) |> body!(201)
    assert_schema(data["data"], "Spec", ctx.spec)
    assert %{"change_id" => "add-x", "latest_version" => 0} = data["data"]
    api_send(:patch, ctx.token, spec_path(ctx), %{change_id: "add-y"}) |> body!(200)

    files = for {p, c} <- spec_files(), do: %{path: p, content: c}

    data =
      api_send(:post, ctx.token, spec_path(ctx, "/versions"), %{
        base_version: 0,
        files: files,
        dry_run: true
      })
      |> body!(200)

    assert %{"version" => nil, "validation" => %{"valid" => true}} = data["data"]

    data =
      api_send(:post, ctx.token, spec_path(ctx, "/versions"), %{base_version: 0, files: files})
      |> body!(201)

    assert_schema(data["data"], "SpecVersionResult", ctx.spec)

    api_send(:post, ctx.token, spec_path(ctx, "/versions"), %{base_version: 0, files: files})
    |> error!(409, "stale_version")
    |> then(&assert(&1 == %{"latest" => 1}))

    data =
      api_send(:post, ctx.token, spec_path(ctx, "/review-requests"), %{reviewers: ["keel/review"]})
      |> body!(201)

    assert_schema(data["data"], "SpecRequests", ctx.spec)

    data =
      api_send(:delete, ctx.token, spec_path(ctx, "/review-requests/keel%2Freview"))
      |> body!(200)

    assert %{"request" => 1, "reviewer" => "keel/review"} = data["data"]
    assert_schema(data["data"], "SpecCancelResult", ctx.spec)

    bob = token_for(ctx.bob, ctx.workspace)

    data =
      api_send(:post, bob, spec_path(ctx, "/reviews"), %{
        version: 1,
        verdict: "fail",
        summary: "No.",
        issues: [%{severity: "P1", body: "Why?"}]
      })
      |> body!(201)

    assert %{"review" => 1, "issues" => ["R1.1"]} = data["data"]
    assert_schema(data["data"], "SpecReviewResult", ctx.spec)

    api_send(:post, ctx.token, spec_path(ctx, "/finalize"), %{version: 1})
    |> error!(409, "unresolved_issues")
    |> then(&assert(&1 == %{"issues" => ["R1.1"]}))

    data =
      api_send(:post, ctx.token, spec_path(ctx, "/issues/R1.1/notes"), %{body: "Noted."})
      |> body!(201)

    assert_schema(data["data"], "SpecNoteResult", ctx.spec)

    data =
      api_send(:post, ctx.token, spec_path(ctx, "/issues/R1.1/ruling"), %{
        ruling: "dismissed",
        reason: "Fine."
      })
      |> body!(201)

    assert %{"ref" => "R1.1", "resolution" => "dismissed"} = data["data"]

    api_send(:post, ctx.token, spec_path(ctx, "/issues/R9.1/notes"), %{body: "x"})
    |> error!(404, "issue_not_found")

    data = api_send(:post, ctx.token, spec_path(ctx, "/finalize"), %{version: 1}) |> body!(200)
    assert %{"status" => "finalized", "decision" => "finalized"} = data["data"]

    api_send(:post, ctx.token, spec_path(ctx, "/versions"), %{base_version: 1, files: files})
    |> error!(409, "spec_closed")
  end

  test "export: an attachment whose top directory is change_id", ctx do
    spec_fixture(ctx.alice_scope, ctx.ident, versions: 3, change_id: "add-settings-page")
    conn = api_get(ctx.token, spec_path(ctx, "/export?format=tar.gz"), [{"accept", "*/*"}])

    assert conn.status == 200
    assert get_resp_header(conn, "content-type") == ["application/gzip"]

    assert get_resp_header(conn, "content-disposition") ==
             [~s[attachment; filename="add-settings-page-v3.tar.gz"]]

    {:ok, names} = :erl_tar.table({:binary, :zlib.gunzip(conn.resp_body)})
    assert Enum.all?(names, &String.starts_with?(List.to_string(&1), "add-settings-page/"))

    conn = api_get(ctx.token, spec_path(ctx, "/export?format=zip&version=1&reviews=true"))
    assert get_resp_header(conn, "content-type") == ["application/zip"]
    assert {:ok, _files} = :zip.unzip(conn.resp_body, [:memory])

    api_get(ctx.token, spec_path(ctx, "/export?format=rar")) |> error!(400, "invalid_params")
    api_get(ctx.token, spec_path(ctx, "/export?version=9")) |> error!(404, "version_not_found")
  end

  test "import: a new version, a dry run, stale and invalid archives", ctx do
    archive = change_archive("openspec/changes/add-x/")
    {conn, _ref} = import(ctx, ctx.token, "?base_version=0&note=hi", @gzip, archive)
    data = body!(conn, 201)
    assert %{"version" => 1, "warnings" => []} = data["data"]
    assert_schema(data["data"], "SpecVersionResult", ctx.spec)
    assert {:ok, %{change_id: "add-x"}} = TaskSpecs.summary(ctx.alice_scope, ctx.ident)

    {conn, _ref} = import(ctx, ctx.token, "?base_version=1", @gzip, archive)
    error!(conn, 409, "no_changes")

    spec_fixture(ctx.alice_scope, ctx.ident, versions: 0)
    other = change_archive("add-x/", spec_files(tag: "2"))

    {conn, _ref} = import(ctx, ctx.token, "?base_version=1&dry_run=true", @gzip, other)
    data = body!(conn, 200)
    assert %{"dry_run" => true, "version" => nil, "diff" => %{"files" => [_ | _]}} = data["data"]

    {conn, _ref} = import(ctx, ctx.token, "?base_version=1", @gzip, other)
    assert %{"version" => 2} = body!(conn, 201)["data"]

    {conn, _ref} = import(ctx, ctx.token, "?base_version=1", @gzip, other)
    assert error!(conn, 409, "stale_version") == %{"latest" => 2}

    {conn, _ref} =
      import(ctx, ctx.token, "?base_version=2", [{"content-type", "application/zip"}], "PK..")

    assert %{"reason" => _} = error!(conn, 422, "invalid_archive")
  end

  test "import: denials before the body is read", ctx do
    spec_fixture(ctx.alice_scope, ctx.ident)
    {_user, viewer} = member_token(ctx.workspace, :viewer)
    read_only = token_for(ctx.alice, ctx.workspace, %{scopes: ["api:read"]})

    {_scope, run_token} =
      run_fixture(ctx.fe, %{task_id: ctx.task.id, status: :running}) |> run_scope_fixture()

    big = [{"content-type", "application/gzip"}, {"content-length", "#{2 * 1024 * 1024 + 1}"}]

    for {token, query, headers, status, code, slug} <- [
          {nil, "?base_version=1", @gzip, 401, "unauthorized", ctx.slug},
          {run_token, "?base_version=1", @gzip, 401, "unauthorized", ctx.slug},
          {read_only, "?base_version=1", @gzip, 403, "insufficient_scope", ctx.slug},
          {ctx.token, "?base_version=1", @gzip, 404, "not_found", "other-workspace"},
          {viewer, "?base_version=1", @gzip, 403, "forbidden", ctx.slug},
          {ctx.token, "", @gzip, 400, "invalid_params", ctx.slug},
          {ctx.token, "?base_version=x", @gzip, 400, "invalid_params", ctx.slug},
          {ctx.token, "?base_version=1", [{"x-helmsman-actor", "nobody/x"} | @gzip], 403,
           "forbidden", ctx.slug},
          {ctx.token, "?base_version=1", [{"content-type", "application/json"}], 415,
           "unsupported_media_type", ctx.slug},
          {ctx.token, "?base_version=1", [{"content-type", "text/plain"}], 415,
           "unsupported_media_type", ctx.slug},
          {ctx.token, "?base_version=1", big, 413, "payload_too_large", ctx.slug}
        ] do
      {conn, ref} = import(%{ctx | slug: slug}, token, query, headers, "{}")
      error!(conn, status, code)
      refute_received {:upload_read, ^ref}, "#{status} #{code} read the body"
    end

    {conn, ref} =
      import(%{ctx | ident: "NOPE-1"}, ctx.token, "?base_version=1", @gzip, change_archive("x/"))

    error!(conn, 404, "not_found")
    refute_received {:upload_read, ^ref}

    huge = :binary.copy("a", 2 * 1024 * 1024 + 10)
    {conn, ref} = import(ctx, ctx.token, "?base_version=1", @gzip, huge)
    error!(conn, 413, "payload_too_large")
    assert_received {:upload_read, ^ref}
    assert {:ok, %{latest_version: 1}} = TaskSpecs.summary(ctx.alice_scope, ctx.ident)
  end

  test "run tokens get 401 on every spec endpoint", ctx do
    spec_fixture(ctx.alice_scope, ctx.ident)

    {_scope, run_token} =
      run_fixture(ctx.fe, %{task_id: ctx.task.id, status: :running}) |> run_scope_fixture()

    api_get(run_token, spec_path(ctx)) |> error!(401, "unauthorized")
    api_get(run_token, spec_path(ctx, "/export")) |> error!(401, "unauthorized")

    api_send(:post, run_token, spec_path(ctx, "/versions"), %{base_version: 1})
    |> error!(401, "unauthorized")
  end
end
