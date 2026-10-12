defmodule HelmsmanWeb.Plugs.MCPSessionGuardTest do
  use ExUnit.Case, async: true

  import Plug.Conn

  alias Helmsman.Accounts.{Scope, User}
  alias Helmsman.ApiTokens.ApiToken
  alias Helmsman.Workspaces.Workspace
  alias HelmsmanMCP.Sessions
  alias HelmsmanWeb.Plugs.MCPSessionGuard

  defp scope(user_id, token_id) do
    %Scope{
      user: %User{id: user_id},
      workspace: %Workspace{id: 1},
      token: %ApiToken{id: token_id},
      via: :mcp
    }
  end

  setup do
    n = System.unique_integer([:positive]) * 10
    alice = scope(n, n + 1)
    session_id = "guard-#{n}"
    :ok = Sessions.register(session_id, alice, self())

    %{
      alice: alice,
      alice2: scope(n, n + 2),
      bob: scope(n + 3, n + 4),
      session_id: session_id
    }
  end

  defp request(scope, session_id, body \\ %{"method" => "tools/list"}) do
    conn = Plug.Test.conn(:post, "/mcp", Jason.encode!(body))
    conn = if session_id, do: put_req_header(conn, "mcp-session-id", session_id), else: conn

    conn
    |> assign(:current_scope, scope)
    |> MCPSessionGuard.call(MCPSessionGuard.init([]))
  end

  defp assert_not_found(conn) do
    assert conn.halted
    assert conn.status == 404

    assert %{"error" => %{"data" => %{"message" => "Session not found"}}} =
             Jason.decode!(conn.resp_body)
  end

  test "no session header passes", %{bob: bob} do
    refute request(bob, nil).halted
  end

  test "the session's own token passes", %{alice: alice, session_id: session_id} do
    conn = request(alice, session_id)
    refute conn.halted
    assert conn.status == nil
    _ = :sys.get_state(Sessions)
    assert %{pid: pid} = Sessions.lookup(session_id)
    assert pid == self()
  end

  test "an unregistered session is 404", %{alice: alice} do
    assert_not_found(request(alice, "never-registered"))
  end

  test "another user's token is 404", %{bob: bob, session_id: session_id} do
    assert_not_found(request(bob, session_id))
  end

  test "another token of the same user is 404", %{alice2: alice2, session_id: session_id} do
    assert_not_found(request(alice2, session_id))
  end

  test "initialize with someone else's session ID is 404", %{bob: bob, session_id: session_id} do
    assert_not_found(request(bob, session_id, %{"method" => "initialize"}))
  end
end
