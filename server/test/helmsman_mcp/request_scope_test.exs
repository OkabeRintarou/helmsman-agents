defmodule HelmsmanMCP.RequestScopeTest do
  use Helmsman.DataCase, async: true

  import Helmsman.AccountsFixtures
  import Helmsman.ApiTokensFixtures
  import Helmsman.WorkspacesFixtures

  alias Helmsman.Accounts.Scope
  alias Helmsman.ApiTokens.ApiToken
  alias Helmsman.Workspaces.Membership
  alias HelmsmanMCP.{RequestScope, Sessions}

  setup do
    owner = user_fixture()
    workspace = workspace_fixture(owner)
    alice = user_fixture()
    member_fixture(workspace, alice, :member)
    alice_web = workspace_scope_fixture(alice, workspace)
    %{token: token, api_token: api_token} = api_token_fixture(alice_web, %{scopes: ["mcp"]})
    sid = "request-scope-#{System.unique_integer([:positive])}"
    :ok = Sessions.register(sid, token_scope_fixture(alice, workspace, :mcp, api_token), self())

    %{
      token: token,
      api_token: api_token,
      sid: sid,
      alice: alice,
      alice_web: alice_web,
      workspace: workspace
    }
  end

  defp headers(token), do: %{"authorization" => "Bearer " <> token}

  test "the token's current user, workspace and role", ctx do
    Repo.update_all(where(Membership, user_id: ^ctx.alice.id), set: [role: :viewer])

    assert {:ok, %Scope{via: :mcp, role: :viewer, actor: nil} = scope} =
             RequestScope.fetch(headers(ctx.token), ctx.sid)

    assert {scope.user.id, scope.workspace.id, scope.token.id} ==
             {ctx.alice.id, ctx.workspace.id, ctx.api_token.id}

    assert {:ok, _} = RequestScope.fetch(%{"authorization" => "bearer  " <> ctx.token}, ctx.sid)
  end

  test "another token, even of the same user, is refused", ctx do
    %{token: other} = api_token_fixture(ctx.alice_web, %{scopes: ["mcp"]})
    assert RequestScope.fetch(headers(other), ctx.sid) == {:error, :unauthorized}
  end

  test "no header, an unknown session, a revoked token or no mcp scope", ctx do
    assert RequestScope.fetch(%{}, ctx.sid) == {:error, :unauthorized}
    assert RequestScope.fetch(%{"authorization" => ctx.token}, ctx.sid) == {:error, :unauthorized}
    assert RequestScope.fetch(headers(ctx.token), "unknown") == {:error, :unauthorized}
    assert RequestScope.fetch(headers(ctx.token), nil) == {:error, :unauthorized}

    Repo.update_all(where(ApiToken, id: ^ctx.api_token.id), set: [scopes: ["api:read"]])
    assert RequestScope.fetch(headers(ctx.token), ctx.sid) == {:error, :unauthorized}

    Repo.update_all(where(ApiToken, id: ^ctx.api_token.id),
      set: [scopes: ["mcp"], revoked_at: DateTime.utc_now(:second)]
    )

    assert RequestScope.fetch(headers(ctx.token), ctx.sid) == {:error, :unauthorized}
  end
end
