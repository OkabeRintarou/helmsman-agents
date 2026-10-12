defmodule HelmsmanWeb.DaemonChannelTest do
  # Not async: some tests change global settings (the daemon clock, forced :busy).
  use ExUnit.Case, async: false

  import Phoenix.ChannelTest
  import Ecto.Query, only: [from: 2]
  import Helmsman.AccountsFixtures
  import Helmsman.AgentsFixtures
  import Helmsman.WorkspacesFixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias Helmsman.Accounts.Scope
  alias Helmsman.{Daemons, Repo}
  alias Helmsman.Daemons.{Daemon, DaemonWorkspace, Runtime}
  alias HelmsmanProtocol.DeviceAuth.{CodeRequest, TokenResponse}
  alias HelmsmanProtocol.{ErrorReply, Messages, Push, Reply, Report}
  alias HelmsmanWeb.{DaemonChannel, DaemonSocket}

  @endpoint HelmsmanWeb.Endpoint

  setup do
    pid = Sandbox.start_owner!(Repo, shared: true)
    on_exit(fn -> Sandbox.stop_owner(pid) end)

    alice = user_fixture()
    acme = workspace_fixture(alice, %{slug: "acme#{System.unique_integer([:positive])}"})
    beta = workspace_fixture(alice, %{slug: "beta#{System.unique_integer([:positive])}"})

    {daemon, token} =
      daemon_fixture(alice, %{
        workspace_ids: [acme.id, beta.id],
        last_seen_at: DateTime.add(Daemons.now(), -60)
      })

    %{
      alice: alice,
      scope: Scope.for_user(alice),
      acme: acme,
      beta: beta,
      daemon: daemon,
      token: token
    }
  end

  ## Helpers

  defp connect_daemon(token) do
    connect(DaemonSocket, %{},
      connect_info: %{x_headers: [{HelmsmanProtocol.token_header(), token}]}
    )
  end

  defp machine(daemon) do
    %{
      machine_id: daemon.machine_id,
      name: "alice-laptop",
      os: "linux",
      arch: "aarch64",
      daemon_version: "0.2.0"
    }
  end

  defp claude,
    do: %{
      provider: :claude,
      version: "2.0.0",
      models: ["opus"],
      efforts: [],
      available: true,
      unavailable_reason: nil
    }

  defp old_codex,
    do: %{
      provider: :codex,
      version: "0.1.0",
      models: [],
      efforts: [],
      available: false,
      unavailable_reason: "version too old"
    }

  defp encode!(struct) do
    {:ok, {_name, payload}} = Messages.encode(struct)
    payload
  end

  defp join_payload(daemon, clis, attrs \\ %{}) do
    {:ok, report} =
      Report.Join.new(
        Map.merge(
          %{
            protocol: HelmsmanProtocol.version(),
            machine: machine(daemon),
            clis: clis,
            max_concurrency: 6,
            active_runs: []
          },
          attrs
        )
      )

    encode!(report)
  end

  defp sync_payload(daemon, clis) do
    {:ok, report} = Report.Sync.new(%{machine: machine(daemon), clis: clis, max_concurrency: 6})
    encode!(report)
  end

  defp join_daemon(socket, id, payload), do: join(socket, DaemonChannel, "daemon:#{id}", payload)

  # Connects with `token` and joins the daemon's own topic.
  defp joined(daemon, token, clis \\ [claude()]) do
    {:ok, socket} = connect_daemon(token)
    assert {:ok, reply, socket} = join_daemon(socket, daemon.id, join_payload(daemon, clis))
    assert {:ok, %Reply.Join{} = reply} = Messages.decode_reply("join", reply)
    {socket, reply}
  end

  defp error_reason(payload) do
    assert {:ok, %ErrorReply{} = error} = ErrorReply.from_wire(payload)
    error.reason
  end

  defp runtimes(daemon),
    do:
      Repo.all(
        from r in Runtime,
          where: r.daemon_id == ^daemon.id,
          order_by: [r.workspace_id, r.provider]
      )

  # Re-login on the same machine through the device flow (decision 8).
  defp relogin(scope, daemon, workspace_ids) do
    {:ok, request} =
      CodeRequest.new(%{protocol: HelmsmanProtocol.version(), machine: machine(daemon)})

    {:ok, code} = Daemons.start_device_auth(request)
    {:ok, _} = Daemons.approve_device(scope, code.user_code, workspace_ids)
    {:ok, %TokenResponse{token: token}} = Daemons.exchange_device_code(code.device_code)
    token
  end

  defp socket_topic(socket), do: DaemonSocket.id(socket)

  defp watch(socket) do
    @endpoint.subscribe(socket_topic(socket))
    Process.monitor(socket.channel_pid)
  end

  defp assert_disconnected(socket, monitor) do
    pid = socket.channel_pid
    topic = socket_topic(socket)
    assert_receive {:DOWN, ^monitor, :process, ^pid, _reason}
    assert_receive %Phoenix.Socket.Broadcast{topic: ^topic, event: "disconnect"}
  end

  # Runs `fun` while the channel process is suspended, so messages pushed before it
  # are handled only after what `fun` commits.
  defp while_suspended(socket, fun) do
    :sys.suspend(socket.channel_pid)

    try do
      fun.()
    after
      :sys.resume(socket.channel_pid)
    end
  end

  defp put_env(key, value) do
    previous = Application.fetch_env(:helmsman, key)
    Application.put_env(:helmsman, key, value)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:helmsman, key, value)
        :error -> Application.delete_env(:helmsman, key)
      end
    end)
  end

  ## join（守护进程连接与注册）

  describe "join" do
    test "first join registers a runtime per workspace and CLI (spec 首次 join)", ctx do
      {_socket, reply} = joined(ctx.daemon, ctx.token, [claude(), old_codex()])

      rows = runtimes(ctx.daemon)
      assert length(rows) == 4

      for workspace <- [ctx.acme, ctx.beta] do
        assert %{
                 status: "online",
                 unavailable_reason: nil,
                 cli_version: "2.0.0",
                 models: ["opus"]
               } =
                 Enum.find(rows, &(&1.workspace_id == workspace.id and &1.provider == "claude"))

        assert %{status: "offline", unavailable_reason: "version too old"} =
                 Enum.find(rows, &(&1.workspace_id == workspace.id and &1.provider == "codex"))
      end

      assert reply.daemon_id == ctx.daemon.id
      assert reply.terminate_run_ids == []

      online = Enum.filter(rows, &(&1.provider == "claude"))

      assert Enum.sort_by(reply.runtimes, & &1.runtime_id) ==
               online
               |> Enum.map(fn row ->
                 slug = if row.workspace_id == ctx.acme.id, do: ctx.acme.slug, else: ctx.beta.slug

                 %HelmsmanProtocol.Runtime{
                   workspace_id: row.workspace_id,
                   workspace_slug: slug,
                   provider: :claude,
                   runtime_id: row.id
                 }
               end)
               |> Enum.sort_by(& &1.runtime_id)

      daemon = Repo.get!(Daemon, ctx.daemon.id)
      assert {daemon.os, daemon.arch, daemon.version} == {"linux", "aarch64", "0.2.0"}
      assert daemon.max_concurrency == 6
      assert daemon.protocol_version == HelmsmanProtocol.version()
      assert DateTime.diff(Daemons.now(), daemon.last_seen_at) < 5
    end

    test "joining again after a restart keeps the runtimes (spec 重启后再次 join)", ctx do
      {socket, first} = joined(ctx.daemon, ctx.token, [claude(), old_codex()])
      ids = Enum.map(runtimes(ctx.daemon), & &1.id)
      Process.unlink(socket.channel_pid)
      close(socket)

      {_socket, second} = joined(ctx.daemon, ctx.token, [claude(), old_codex()])
      assert Enum.map(runtimes(ctx.daemon), & &1.id) == ids
      assert second.runtimes == first.runtimes
    end

    test "another daemon's topic is not_found (spec 加入别人的 Topic)", ctx do
      {other, _token} = daemon_fixture(user_fixture())
      {:ok, socket} = connect_daemon(ctx.token)

      for id <- [other.id, ctx.daemon.id + 100_000] do
        assert {:error, reply} = join_daemon(socket, id, join_payload(ctx.daemon, [claude()]))
        assert error_reason(reply) == :not_found
      end

      assert runtimes(ctx.daemon) == []
    end

    test "an invalid payload is invalid_payload", ctx do
      {:ok, socket} = connect_daemon(ctx.token)

      for payload <- [%{}, %{"protocol" => 1}, Map.put(join_payload(ctx.daemon, []), "clis", "x")] do
        assert {:error, reply} = join_daemon(socket, ctx.daemon.id, payload)
        assert error_reason(reply) == :invalid_payload
      end
    end

    test "an incompatible protocol is unsupported_protocol with versions and upgrade address",
         ctx do
      {:ok, socket} = connect_daemon(ctx.token)
      payload = join_payload(ctx.daemon, [claude()], %{protocol: HelmsmanProtocol.version() + 1})

      assert {:error, reply} = join_daemon(socket, ctx.daemon.id, payload)
      assert {:ok, error} = ErrorReply.from_wire(reply)
      assert error.reason == :unsupported_protocol
      assert error.server_version == HelmsmanProtocol.version()
      assert error.min_version == HelmsmanProtocol.min_version()
      assert error.upgrade_url == HelmsmanWeb.DaemonDeviceController.upgrade_url()
      assert runtimes(ctx.daemon) == []
    end

    test "joining after the daemon was revoked is not_found and disconnects", ctx do
      {:ok, socket} = connect_daemon(ctx.token)
      topic = socket_topic(socket)
      @endpoint.subscribe(topic)
      {:ok, _} = Daemons.revoke(ctx.scope, ctx.daemon.id)

      assert {:error, reply} =
               join_daemon(socket, ctx.daemon.id, join_payload(ctx.daemon, [claude()]))

      assert error_reason(reply) == :not_found
      assert_receive %Phoenix.Socket.Broadcast{topic: ^topic, event: "disconnect"}
      assert runtimes(ctx.daemon) == []
    end

    test "a busy registration is wrong_state", ctx do
      put_env(:daemon_locked_force_busy, 3)
      {:ok, socket} = connect_daemon(ctx.token)

      assert {:error, reply} =
               join_daemon(socket, ctx.daemon.id, join_payload(ctx.daemon, [claude()]))

      assert error_reason(reply) == :wrong_state
    end
  end

  ## sync

  describe "sync" do
    test "updates the runtimes; CLIs no longer reported go offline", ctx do
      {socket, _} = joined(ctx.daemon, ctx.token, [claude(), old_codex()])
      ids = Enum.map(runtimes(ctx.daemon), & &1.id)

      ref = push(socket, "sync", sync_payload(ctx.daemon, [claude()]))
      assert_reply ref, :ok, reply
      assert {:ok, %Reply.Join{runtimes: listed}} = Messages.decode_reply("sync", reply)
      assert length(listed) == 2

      rows = runtimes(ctx.daemon)
      assert Enum.map(rows, & &1.id) == ids

      assert rows
             |> Enum.filter(&(&1.provider == "codex"))
             |> Enum.map(&{&1.status, &1.unavailable_reason}) ==
               [{"offline", "not detected"}, {"offline", "not detected"}]
    end

    test "an invalid payload is invalid_payload", ctx do
      {socket, _} = joined(ctx.daemon, ctx.token)
      ref = push(socket, "sync", %{"clis" => []})
      assert_reply ref, :error, reply
      assert error_reason(reply) == :invalid_payload
      assert Process.alive?(socket.channel_pid)
    end

    test "busy after retries replies wrong_state and closes the topic (decision 24)", ctx do
      {socket, _} = joined(ctx.daemon, ctx.token)
      Process.unlink(socket.channel_pid)
      monitor = Process.monitor(socket.channel_pid)
      put_env(:daemon_locked_force_busy, 3)

      ref = push(socket, "sync", sync_payload(ctx.daemon, [claude()]))
      assert_reply ref, :error, reply
      assert error_reason(reply) == :wrong_state
      pid = socket.channel_pid
      assert_receive {:DOWN, ^monitor, :process, ^pid, _}
    end
  end

  ## 守护进程令牌

  describe "rotate_token" do
    test "returns a new token; both work until the old one expires after 24 hours", ctx do
      {socket, _} = joined(ctx.daemon, ctx.token)

      ref = push(socket, "rotate_token", encode!(%Report.RotateToken{}))
      assert_reply ref, :ok, reply

      assert {:ok, %Reply.RotateToken{token: "hmd_" <> _ = new}} =
               Messages.decode_reply("rotate_token", reply)

      assert new != ctx.token

      assert {:ok, _} = connect_daemon(new)
      assert {:ok, old_socket} = connect_daemon(ctx.token)
      # Rotation keeps the login: same epoch, same socket id.
      assert socket_topic(old_socket) == socket_topic(socket)

      later = DateTime.add(DateTime.utc_now(), 86_400 + 60)
      put_env(:daemon_clock, fn -> later end)

      assert connect_daemon(ctx.token) == :error
      assert {:ok, _} = connect_daemon(new)
    end
  end

  describe "revocation" do
    test "a connected daemon gets revoked and is disconnected (spec 吊销正在连接的守护进程)",
         ctx do
      {socket, _} = joined(ctx.daemon, ctx.token)
      Process.unlink(socket.channel_pid)
      monitor = watch(socket)

      {:ok, _} = Daemons.revoke(ctx.scope, ctx.daemon.id)

      assert_push "revoked", payload
      assert {:ok, %Push.Revoked{}} = Messages.decode("revoked", payload)
      assert_disconnected(socket, monitor)
      assert connect_daemon(ctx.token) == :error
      assert Enum.all?(runtimes(ctx.daemon), &(&1.status == "offline"))
    end

    test "re-login right after revoking: no revoked push, disconnected (spec 吊销后立即重新登录)",
         ctx do
      {socket, _} = joined(ctx.daemon, ctx.token)
      Process.unlink(socket.channel_pid)
      monitor = watch(socket)

      new_token =
        while_suspended(socket, fn ->
          {:ok, _} = Daemons.revoke(ctx.scope, ctx.daemon.id)
          relogin(ctx.scope, ctx.daemon, [ctx.acme.id])
        end)

      assert_disconnected(socket, monitor)
      refute_push "revoked", _

      assert {:ok, new_socket} = connect_daemon(new_token)
      assert socket_topic(new_socket) != socket_topic(socket)
    end

    test "a sync received before the revocation commits is not_found (spec 吊销后到达的上报)",
         ctx do
      {socket, _} = joined(ctx.daemon, ctx.token)
      Process.unlink(socket.channel_pid)
      monitor = watch(socket)

      ref =
        while_suspended(socket, fn ->
          ref = push(socket, "sync", sync_payload(ctx.daemon, [claude()]))
          {:ok, _} = Daemons.revoke(ctx.scope, ctx.daemon.id)
          ref
        end)

      assert_reply ref, :error, reply
      assert error_reason(reply) == :not_found
      assert_disconnected(socket, monitor)
      assert Enum.all?(runtimes(ctx.daemon), &(&1.status == "offline"))
      assert Repo.get!(Daemon, ctx.daemon.id).revoked_at
    end
  end

  ## 同机重新登录时旧连接仍在

  describe "re-login on the same machine while the old connection is open" do
    setup ctx do
      Repo.delete_all(from w in DaemonWorkspace, where: w.workspace_id == ^ctx.beta.id)

      {socket, _} = joined(ctx.daemon, ctx.token)
      Process.unlink(socket.channel_pid)
      [acme_runtime] = runtimes(ctx.daemon)
      %{old: socket, acme_runtime: acme_runtime}
    end

    test "the old connection's sync is not_found and registers nothing for beta", ctx do
      monitor = watch(ctx.old)

      {ref, new_token} =
        while_suspended(ctx.old, fn ->
          ref = push(ctx.old, "sync", sync_payload(ctx.daemon, [claude()]))
          {ref, relogin(ctx.scope, ctx.daemon, [ctx.acme.id, ctx.beta.id])}
        end)

      assert_reply ref, :error, reply
      assert error_reason(reply) == :not_found
      assert runtimes(ctx.daemon) |> Enum.map(& &1.workspace_id) == [ctx.acme.id]
      assert_disconnected(ctx.old, monitor)
      refute_push "revoked", _

      # The new login: a different socket id, not touched by the old one's disconnect.
      {:ok, new_socket} = connect_daemon(new_token)
      new_topic = socket_topic(new_socket)
      assert new_topic != socket_topic(ctx.old)
      @endpoint.subscribe(new_topic)

      assert {:ok, reply, new_socket} =
               join_daemon(new_socket, ctx.daemon.id, join_payload(ctx.daemon, [claude()]))

      assert {:ok, %Reply.Join{runtimes: listed}} = Messages.decode_reply("join", reply)

      assert listed |> Enum.map(& &1.workspace_id) |> Enum.sort() ==
               Enum.sort([ctx.acme.id, ctx.beta.id])

      assert Enum.find(listed, &(&1.workspace_id == ctx.acme.id)).runtime_id ==
               ctx.acme_runtime.id

      refute_receive %Phoenix.Socket.Broadcast{topic: ^new_topic, event: "disconnect"}
      assert Process.alive?(new_socket.channel_pid)
    end

    test "the old connection's rotate_token is not_found and issues no token", ctx do
      monitor = watch(ctx.old)

      {ref, new_token} =
        while_suspended(ctx.old, fn ->
          ref = push(ctx.old, "rotate_token", encode!(%Report.RotateToken{}))
          {ref, relogin(ctx.scope, ctx.daemon, [ctx.acme.id, ctx.beta.id])}
        end)

      assert_reply ref, :error, reply
      assert error_reason(reply) == :not_found
      assert_disconnected(ctx.old, monitor)
      refute_push "revoked", _

      daemon = Repo.get!(Daemon, ctx.daemon.id)
      assert daemon.token_hash == Daemons.hash(new_token)
      assert is_nil(daemon.previous_token_hash)
      assert connect_daemon(ctx.token) == :error
    end

    test "the old connection is disconnected on the re-authorization notice", ctx do
      monitor = watch(ctx.old)
      _new_token = relogin(ctx.scope, ctx.daemon, [ctx.acme.id, ctx.beta.id])

      assert_disconnected(ctx.old, monitor)
      refute_push "revoked", _
    end
  end

  ## 本变更范围内的运行消息

  describe "run messages before run dispatch exists" do
    test "heartbeat replies no terminations and refreshes last_seen_at", ctx do
      {socket, _} = joined(ctx.daemon, ctx.token)
      stale = DateTime.add(Daemons.now(), -60)

      Repo.update_all(from(d in Daemon, where: d.id == ^ctx.daemon.id),
        set: [last_seen_at: stale]
      )

      ref = push(socket, "heartbeat", encode!(%Report.Heartbeat{runs: []}))
      assert_reply ref, :ok, reply

      assert {:ok, %Reply.Heartbeat{terminate_run_ids: []}} =
               Messages.decode_reply("heartbeat", reply)

      seen = Repo.get!(Daemon, ctx.daemon.id).last_seen_at
      assert DateTime.compare(seen, stale) == :gt
      assert DateTime.diff(Daemons.now(), seen) < 5
    end

    test "claim replies an empty run list (spec 空领取)", ctx do
      {socket, _} = joined(ctx.daemon, ctx.token)
      stale = DateTime.add(Daemons.now(), -60)

      Repo.update_all(from(d in Daemon, where: d.id == ^ctx.daemon.id),
        set: [last_seen_at: stale]
      )

      ref = push(socket, "claim", encode!(%Report.Claim{}))
      assert_reply ref, :ok, reply
      assert {:ok, %Reply.Claim{runs: []}} = Messages.decode_reply("claim", reply)
      assert Repo.get!(Daemon, ctx.daemon.id).last_seen_at == stale
    end

    test "starting is not_found and keeps the connection", ctx do
      {socket, _} = joined(ctx.daemon, ctx.token)
      {:ok, starting} = Report.Starting.new(%{run_id: 1})

      ref = push(socket, "starting", encode!(starting))
      assert_reply ref, :error, reply
      assert error_reason(reply) == :not_found
      assert Process.alive?(socket.channel_pid)
    end

    test "an unknown message is invalid_payload", ctx do
      {socket, _} = joined(ctx.daemon, ctx.token)
      ref = push(socket, "bogus", %{})
      assert_reply ref, :error, reply
      assert error_reason(reply) == :invalid_payload
    end
  end

  test "config changes are pushed once as config_changed", ctx do
    # join/4 (not subscribe_and_join): the test process is not subscribed to the topic.
    {socket, _} = joined(ctx.daemon, ctx.token)
    pid = socket.channel_pid
    topic = Helmsman.Events.topic(:daemon, ctx.daemon.id)
    subscribers = for {^pid, _} <- Registry.lookup(Helmsman.PubSub, topic), do: pid

    assert subscribers == [pid],
           "the channel is subscribed to #{topic} #{length(subscribers)} times"

    refute self() in Enum.map(Registry.lookup(Helmsman.PubSub, topic), &elem(&1, 0))

    {:ok, _} = Daemons.set_workspaces(ctx.scope, ctx.daemon.id, [ctx.acme.id])

    assert_push "config_changed", payload
    assert {:ok, %Push.ConfigChanged{}} = Messages.decode("config_changed", payload)
    refute_push "config_changed", _
  end
end
