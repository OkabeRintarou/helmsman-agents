defmodule HelmsmanMCP.SessionsTest do
  use ExUnit.Case, async: true

  alias Helmsman.Accounts.{Scope, User}
  alias Helmsman.ApiTokens.ApiToken
  alias Helmsman.Workspaces.Workspace
  alias HelmsmanMCP.Sessions

  @max_idle_ms :timer.hours(24) + :timer.minutes(5)

  defp scope do
    n = System.unique_integer([:positive])
    %Scope{token: %ApiToken{id: n}, user: %User{id: n + 1}, workspace: %Workspace{id: n + 2}}
  end

  defp session_id, do: "test-session-#{System.unique_integer([:positive])}"

  defp idler do
    start_supervised!(
      Supervisor.child_spec({Agent, fn -> nil end}, id: make_ref(), restart: :temporary)
    )
  end

  defp kill(pid) do
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}
    _ = :sys.get_state(Sessions)
  end

  test "register, lookup, put_identity and delete" do
    id = session_id()
    scope = scope()
    assert Sessions.lookup(id) == nil

    assert :ok = Sessions.register(id, scope, self())

    assert %{
             credential: credential,
             user_id: user_id,
             workspace_id: workspace_id,
             pid: pid,
             actor_id: nil,
             source: nil
           } = Sessions.lookup(id)

    assert {credential, user_id, workspace_id, pid} ==
             {{:api_token, scope.token.id}, scope.user.id, scope.workspace.id, self()}

    assert :ok = Sessions.put_identity(id, 42, :identify)
    assert %{actor_id: 42, source: :identify} = Sessions.lookup(id)
    assert :error = Sessions.put_identity(session_id(), 42, :auto)

    assert :ok = Sessions.delete(id, self())
    assert Sessions.lookup(id) == nil
  end

  test "touch within 60 seconds keeps last_seen_at" do
    id = session_id()
    :ok = Sessions.register(id, scope(), self())
    %{last_seen_at: seen} = Sessions.lookup(id)

    assert :ok = Sessions.touch(id)
    _ = :sys.get_state(Sessions)
    assert %{last_seen_at: ^seen} = Sessions.lookup(id)
    assert :ok = Sessions.touch(session_id())
  end

  test "a killed session process is removed" do
    id = session_id()
    pid = idler()
    :ok = Sessions.register(id, scope(), pid)

    kill(pid)
    assert Sessions.lookup(id) == nil
  end

  describe "an ID registered again by another process (decision 14)" do
    setup do
      id = session_id()
      a = idler()
      b = idler()
      :ok = Sessions.register(id, scope(), a)
      :ok = Sessions.register(id, scope(), b)
      %{id: id, a: a, b: b}
    end

    test "A's delete and exit leave B's entry, which stays monitored", %{id: id, a: a, b: b} do
      assert :ok = Sessions.delete(id, a)
      assert %{pid: ^b} = Sessions.lookup(id)

      kill(a)
      assert %{pid: ^b} = Sessions.lookup(id)

      kill(b)
      assert Sessions.lookup(id) == nil
    end

    test "B's delete removes it", %{id: id, a: a, b: b} do
      kill(a)
      assert :ok = Sessions.delete(id, b)
      assert Sessions.lookup(id) == nil
    end
  end

  test "the sweep removes expired entries and keeps the others" do
    old = session_id()
    :ok = Sessions.register(old, scope(), self())
    %{last_seen_at: old_seen} = Sessions.lookup(old)
    wait_until_after(old_seen)

    fresh = session_id()
    :ok = Sessions.register(fresh, scope(), self())

    send(Sessions, {:sweep, old_seen + @max_idle_ms + 1})
    _ = :sys.get_state(Sessions)

    assert Sessions.lookup(old) == nil
    assert %{pid: pid} = Sessions.lookup(fresh)
    assert pid == self()
  end

  defp wait_until_after(ms) do
    if System.monotonic_time(:millisecond) <= ms, do: wait_until_after(ms)
  end
end
