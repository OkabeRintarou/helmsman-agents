defmodule Helmsman.ApiTokensFixtures do
  @moduledoc """
  Test helpers for API tokens, agents and token-authenticated scopes.
  """

  # Test-only helpers used by both domain and web test cases.
  use Boundary, top_level?: true, check: [in: false, out: false]

  alias Helmsman.Accounts.Scope
  alias Helmsman.Actors.Actor
  alias Helmsman.ApiTokens
  alias Helmsman.Repo
  alias Helmsman.Workspaces

  @doc """
  Creates a token as `scope` (scopes `mcp`, `api:read` and `api:write` by
  default) and returns `%{token: plaintext, api_token: record}`.
  """
  def api_token_fixture(scope, attrs \\ %{}) do
    attrs =
      Enum.into(attrs, %{
        name: "token-#{System.unique_integer([:positive])}",
        scopes: ["mcp", "api:read", "api:write"]
      })

    {:ok, created} = ApiTokens.create(scope, attrs)
    created
  end

  @doc "Inserts an agent identity owned by `owner`."
  def agent_fixture(workspace, owner, name, attrs \\ %{}) do
    Repo.insert!(
      struct!(
        %Actor{workspace_id: workspace.id, kind: :agent, name: name, owner_id: owner.id},
        attrs
      )
    )
  end

  @doc """
  The scope a token-authenticated request of `user` in `workspace` gets
  (`via` `:api` or `:mcp`), with the user's current role.
  """
  def token_scope_fixture(user, workspace, via, token \\ nil) do
    membership = Workspaces.get_membership(workspace.id, user.id)

    %Scope{
      user: user,
      workspace: workspace,
      role: membership && membership.role,
      via: via,
      token: token
    }
  end
end
