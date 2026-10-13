defmodule Helmsman.PolicyTest do
  # add-provider-accounts 3.2: who may manage provider accounts (decision
  # 3), with the scopes the entry points really build.
  use Helmsman.DataCase, async: true

  import Helmsman.ApiTokensFixtures
  import Helmsman.RunsFixtures

  alias Helmsman.Accounts.Scope
  alias Helmsman.Policy

  setup do
    dispatch_fixture()
  end

  defp authorize(scope), do: Policy.authorize(scope, :manage_provider_accounts)

  test "the user's own web session passes", ctx do
    assert authorize(Scope.for_user(ctx.alice)) == :ok
    assert ctx.alice_scope.via == :web
    assert authorize(ctx.alice_scope) == :ok
  end

  test "an hm_ token of a person, via MCP or REST, is refused", ctx do
    %{api_token: token} = api_token_fixture(ctx.alice_scope)

    for via <- [:mcp, :api] do
      assert authorize(token_scope_fixture(ctx.alice, ctx.workspace, via, token)) ==
               {:error, :forbidden}
    end
  end

  test "an agent identity is refused", ctx do
    assert authorize(%{ctx.alice_scope | actor: ctx.agent}) == {:error, :forbidden}
  end

  test "a run token is refused, whatever its capabilities", ctx do
    run =
      run_fixture(ctx.agent, %{status: :running, capabilities: ["read", "create_tasks"]})

    {scope, _token} = run_scope_fixture(run)
    assert scope.via == :run and scope.user.id == ctx.alice.id
    assert authorize(scope) == {:error, :forbidden}
  end

  test "a scope without a user, or of another entry point, is refused" do
    assert authorize(%Scope{}) == {:error, :forbidden}

    assert authorize(%Scope{user: %Helmsman.Accounts.User{id: 1}, via: :api}) ==
             {:error, :forbidden}
  end

  test "it is a management action" do
    assert :manage_provider_accounts in Policy.management_actions()
  end
end
