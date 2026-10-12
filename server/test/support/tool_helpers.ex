defmodule HelmsmanMCP.ToolHelpers do
  @moduledoc """
  Test helpers for MCP tools: MCP sessions of a member and calls through
  `HelmsmanMCP.Pipeline`, as the server makes them.
  """

  # Test-only helpers.
  use Boundary, top_level?: true, check: [in: false, out: false]

  import Helmsman.ApiTokensFixtures
  import Helmsman.WorkspacesFixtures

  alias HelmsmanMCP.{Pipeline, Sessions}

  @doc """
  An MCP session of `user` in `workspace` (an `mcp` token, a registered
  session): `%{scope: scope, sid: sid}`. `token_attrs` go to the token.
  """
  def mcp_session(user, workspace, token_attrs \\ %{}) do
    %{api_token: token} = api_token_fixture(workspace_scope_fixture(user, workspace), token_attrs)
    scope = token_scope_fixture(user, workspace, :mcp, token)
    sid = "test-#{System.unique_integer([:positive])}"
    :ok = Sessions.register(sid, scope, self())
    %{scope: scope, sid: sid}
  end

  @doc """
  Calls the tool `name` through the pipeline: `{:ok, decoded_json}` or
  `{:error, text}`.
  """
  def call(%{scope: scope, sid: sid}, name, args \\ %{}) do
    case Pipeline.call_tool(name, args, scope, sid) do
      {:ok, json} -> {:ok, Jason.decode!(json)}
      {:error, text} -> {:error, text}
    end
  end

  @doc "Like `call/3`, for a call that succeeds: the decoded result."
  def call!(session, name, args \\ %{}) do
    {:ok, result} = call(session, name, args)
    result
  end
end
