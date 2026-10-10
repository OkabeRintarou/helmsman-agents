defmodule HelmsmanWeb.Plugs.BearerAuthTest do
  # Changes the token rate limit with Application.put_env.
  use HelmsmanWeb.ConnCase, async: false

  import Ecto.Query
  import Helmsman.AccountsFixtures
  import Helmsman.ApiTokensFixtures
  import Helmsman.WorkspacesFixtures

  alias Helmsman.Accounts.Scope
  alias Helmsman.ApiTokens.ApiToken
  alias Helmsman.Repo
  alias Helmsman.Workspaces.Membership
  alias HelmsmanWeb.Plugs.BearerAuth

  setup do
    owner = user_fixture()
    workspace = workspace_fixture(owner)
    alice = user_fixture()
    member_fixture(workspace, alice, :admin)

    %{token: token, api_token: api_token} =
      api_token_fixture(workspace_scope_fixture(alice, workspace), %{scopes: ["mcp"]})

    %{alice: alice, workspace: workspace, token: token, api_token: api_token}
  end

  defp request(authorization, opts \\ [scope: "mcp", via: :mcp]) do
    conn = Plug.Test.conn(:post, "/mcp")

    conn =
      if authorization,
        do: Plug.Conn.put_req_header(conn, "authorization", authorization),
        else: conn

    BearerAuth.call(conn, BearerAuth.init(opts))
  end

  defp bearer(token), do: request("Bearer " <> token)

  defp assert_error(conn, status, error) do
    assert conn.halted
    assert conn.status == status
    assert Jason.decode!(conn.resp_body) == %{"error" => error}
    conn
  end

  test "a missing or malformed Authorization header is 401 with WWW-Authenticate",
       %{token: token} do
    for header <- [nil, "Basic " <> token, "Bearer", "Bearer hmr_" <> token, "Bearer abc", token] do
      conn = header |> request() |> assert_error(401, "unauthorized")
      assert get_resp_header(conn, "www-authenticate") == ["Bearer"]
    end
  end

  test "a revoked token is 401", %{token: token, api_token: api_token} do
    Repo.update_all(from(t in ApiToken, where: t.id == ^api_token.id),
      set: [revoked_at: DateTime.utc_now(:second)]
    )

    token |> bearer() |> assert_error(401, "unauthorized")
  end

  test "a token without the endpoint's scope is 403", %{token: token} do
    conn = request("Bearer " <> token, scope: "api:read", via: :api)
    assert_error(conn, 403, "forbidden")
    assert get_resp_header(conn, "www-authenticate") == []
  end

  test "a valid token puts the request's scope in the assigns",
       %{token: token, api_token: api_token, alice: alice, workspace: ws} do
    conn = request("bearer " <> token)

    refute conn.halted

    assert %Scope{user: user, workspace: workspace, role: :admin, via: :mcp, actor: nil} =
             scope = conn.assigns.current_scope

    assert user.id == alice.id
    assert workspace.id == ws.id
    assert scope.token.id == api_token.id
  end

  test "a role change applies to the next request",
       %{token: token, alice: alice, workspace: ws} do
    assert bearer(token).assigns.current_scope.role == :admin

    Repo.update_all(
      from(m in Membership, where: m.workspace_id == ^ws.id and m.user_id == ^alice.id),
      set: [role: :member]
    )

    assert bearer(token).assigns.current_scope.role == :member
  end

  test "requests over the token's rate limit are 429 with Retry-After", %{token: token} do
    previous = Application.get_env(:helmsman, :api_token_rate_limit)
    Application.put_env(:helmsman, :api_token_rate_limit, 3)
    on_exit(fn -> Application.put_env(:helmsman, :api_token_rate_limit, previous) end)

    for _ <- 1..3, do: refute(bearer(token).halted)

    conn = token |> bearer() |> assert_error(429, "rate_limited")
    assert [retry_after] = get_resp_header(conn, "retry-after")
    assert String.to_integer(retry_after) > 0
  end

  test "100 requests in a row write last_used_at once", %{token: token, api_token: api_token} do
    # Every UPDATE writes a new row version with a new ctid, even inside
    # the test's transaction.
    version = fn ->
      %{rows: [[ctid, last_used_at]]} =
        Repo.query!("SELECT ctid::text, last_used_at FROM api_tokens WHERE id = $1", [
          api_token.id
        ])

      {ctid, last_used_at}
    end

    {_ctid, nil} = version.()
    refute bearer(token).halted
    {ctid, %{} = last_used_at} = version.()

    for _ <- 2..100, do: refute(bearer(token).halted)

    assert version.() == {ctid, last_used_at}
  end
end
