defmodule HelmsmanWeb.DaemonSocketTest do
  use ExUnit.Case, async: true

  import Phoenix.ChannelTest
  import Helmsman.AccountsFixtures
  import Helmsman.AgentsFixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias Helmsman.Accounts.Scope
  alias Helmsman.{Daemons, Repo}
  alias HelmsmanWeb.DaemonSocket

  @endpoint HelmsmanWeb.Endpoint

  defp connect_with(headers),
    do: connect(DaemonSocket, %{}, connect_info: %{x_headers: headers})

  defp token_header(token), do: [{HelmsmanProtocol.token_header(), token}]

  setup tags do
    pid = Sandbox.start_owner!(Repo, shared: not tags[:async])
    on_exit(fn -> Sandbox.stop_owner(pid) end)

    alice = user_fixture()
    {daemon, token} = daemon_fixture(alice)
    %{alice: alice, daemon: daemon, token: token}
  end

  test "a valid token connects and identifies the daemon and its login", ctx do
    assert {:ok, socket} = connect_with(token_header(ctx.token))

    assert socket.assigns.daemon_id == ctx.daemon.id
    assert socket.assigns.user_id == ctx.alice.id
    assert socket.assigns.auth_epoch == ctx.daemon.auth_epoch
    assert DaemonSocket.id(socket) == "daemon_socket:#{ctx.daemon.id}:#{ctx.daemon.auth_epoch}"
  end

  test "an unknown or malformed token is refused" do
    for token <- ["hmd_" <> String.duplicate("a", 52), "hmd_short", "hm_abc", ""] do
      assert connect_with(token_header(token)) == :error
    end
  end

  test "a revoked token is refused", ctx do
    {:ok, _} = Daemons.revoke(Scope.for_user(ctx.alice), ctx.daemon.id)
    assert connect_with(token_header(ctx.token)) == :error
  end

  test "a missing header is refused", ctx do
    assert connect_with([]) == :error
    assert connect_with([{"x-other", ctx.token}]) == :error
    assert connect(DaemonSocket, %{}) == :error
  end

  test "a token in the query string is not accepted", ctx do
    assert connect(DaemonSocket, %{"token" => ctx.token}) == :error
    assert connect(DaemonSocket, %{"x-helmsman-token" => ctx.token}) == :error

    assert connect(DaemonSocket, %{"x-helmsman-token" => ctx.token},
             connect_info: %{x_headers: []}
           ) == :error
  end

  test "the endpoint mounts the socket at the protocol path, header auth only" do
    assert {_path, DaemonSocket, opts} =
             Enum.find(
               HelmsmanWeb.Endpoint.__sockets__(),
               &(elem(&1, 0) == HelmsmanProtocol.socket_path())
             )

    websocket = Keyword.fetch!(opts, :websocket)
    assert :x_headers in Keyword.fetch!(websocket, :connect_info)
    assert Keyword.fetch!(websocket, :check_origin) == false
    assert Keyword.fetch!(opts, :longpoll) == false
  end
end
