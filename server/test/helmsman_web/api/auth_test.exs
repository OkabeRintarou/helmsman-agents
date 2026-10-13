defmodule HelmsmanWeb.API.AuthTest do
  # rest-api "REST 端点与认证"; add-rest-api decision 14 (authentication).
  use HelmsmanWeb.ConnCase, async: true

  import Ecto.Query
  import Helmsman.AccountsFixtures
  import Helmsman.ProjectsFixtures
  import Helmsman.RunsFixtures
  import Helmsman.WorkspacesFixtures
  import HelmsmanWeb.APIHelpers

  alias Helmsman.ApiTokens.ApiToken
  alias Helmsman.Daemons
  alias Helmsman.Repo
  alias Helmsman.Tasks.Task
  alias Helmsman.Workspaces.Membership

  setup do
    ctx = api_fixture()
    project_fixture(ctx.scope, %{key: "BOS"})
    task_fixture(ctx.scope, "BOS")
    ctx
  end

  test "a read-only token reads but cannot write", %{alice: alice, workspace: ws, slug: slug} do
    read = token_for(alice, ws, %{scopes: ["api:read"]})

    assert read |> api_get(w(slug, "/projects")) |> body!(200)

    detail =
      :post
      |> api_send(read, w(slug, "/projects"), %{key: "NEW", name: "New"})
      |> error!(403, "insufficient_scope")

    assert detail == %{"required" => ["api:write"]}
  end

  test "api:write includes reading", %{alice: alice, workspace: ws, slug: slug} do
    write = token_for(alice, ws, %{scopes: ["api:write"]})

    assert %{"data" => %{"id" => "BOS-1"}} =
             write |> api_get(w(slug, "/tasks/BOS-1")) |> body!(200)
  end

  test "a token with only the mcp scope is 403", %{alice: alice, workspace: ws, slug: slug} do
    mcp = token_for(alice, ws, %{scopes: ["mcp"]})
    mcp |> api_get(w(slug, "/projects")) |> error!(403, "insufficient_scope")
  end

  test "another workspace's slug is 404, whether it exists or not", %{token: token} do
    other = workspace_fixture(user_fixture())

    for slug <- [other.slug, "no-such-workspace"] do
      token |> api_get(w(slug, "/projects")) |> error!(404, "not_found")

      :post
      |> api_send(token, w(slug, "/projects"), %{key: "X", name: "X"})
      |> error!(404, "not_found")
    end
  end

  test "missing, malformed and unknown credentials are 401", %{token: token, slug: slug} do
    for header <- [nil, "Basic " <> token, "Bearer", token, "Bearer hm_nope"] do
      conn = build_conn()
      conn = if header, do: put_req_header(conn, "authorization", header), else: conn
      conn = get(conn, w(slug, "/projects"))

      error!(conn, 401, "unauthorized")
      assert get_resp_header(conn, "www-authenticate") == ["Bearer"]
    end
  end

  test "revoked and expired tokens are 401", %{token: token, api_token: api_token, slug: slug} do
    past = DateTime.add(DateTime.utc_now(:second), -60)

    for change <- [[expires_at: past], [revoked_at: past]] do
      Repo.update_all(from(t in ApiToken, where: t.id == ^api_token.id), set: change)
      token |> api_get(w(slug, "/projects")) |> error!(401, "unauthorized")

      Repo.update_all(from(t in ApiToken, where: t.id == ^api_token.id),
        set: [expires_at: nil, revoked_at: nil]
      )
    end
  end

  test "a token of someone who left the workspace is 401", %{workspace: ws, slug: slug} do
    bob = user_fixture()
    member_fixture(ws, bob, :member)
    token = token_for(bob, ws)

    Repo.delete_all(
      from(m in Membership, where: m.workspace_id == ^ws.id and m.user_id == ^bob.id)
    )

    token |> api_get(w(slug, "/projects")) |> error!(401, "unauthorized")
  end

  test "run and daemon tokens are 401", %{alice: alice, workspace: ws, slug: slug} do
    managed =
      Helmsman.AgentsFixtures.managed_agent_fixture(workspace_scope_fixture(alice, ws), %{
        name: "keel/dev"
      })

    run = run_fixture(agent_actor(ws, managed.name), %{status: :running})
    {_scope, run_token} = run_scope_fixture(run)

    for token <- [run_token, Daemons.new_token()] do
      token |> api_get(w(slug, "/projects")) |> error!(401, "unauthorized")
    end
  end

  test "the current role applies at once", %{alice: alice, workspace: ws, slug: slug} do
    member = user_fixture()
    member_fixture(ws, member, :member)
    token = token_for(member, ws)

    :post
    |> api_send(token, w(slug, "/projects/BOS/tasks"), %{title: "As member"})
    |> body!(201)

    Repo.update_all(
      from(m in Membership, where: m.workspace_id == ^ws.id and m.user_id == ^member.id),
      set: [role: :viewer]
    )

    count = Repo.aggregate(Task, :count)

    :post
    |> api_send(token, w(slug, "/projects/BOS/tasks"), %{title: "As viewer"})
    |> error!(403, "forbidden")

    assert Repo.aggregate(Task, :count) == count
    _ = alice
  end
end
