defmodule HelmsmanWeb.DaemonChannelRepoRegistrationTest do
  # add-local-repo-web-registration 3.4: web registration requests and
  # results on the daemon channel (D9). Payloads are encoded and replies
  # decoded with `HelmsmanProtocol.Messages`, as the daemon does.
  use ExUnit.Case, async: false

  @moduletag :capture_log

  import ExUnit.CaptureLog
  import Phoenix.ChannelTest
  import Ecto.Query, only: [from: 2]
  import Helmsman.AccountsFixtures
  import Helmsman.AgentsFixtures
  import Helmsman.LocalRepositoriesFixtures
  import Helmsman.WorkspacesFixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias Helmsman.Daemons.Daemon
  alias Helmsman.Events
  alias Helmsman.LocalRepositories.{Change, LocalRepository, WebRegistration}
  alias Helmsman.Repo
  alias HelmsmanProtocol.{ErrorReply, Messages, Push, Report}
  alias HelmsmanWeb.{DaemonChannel, DaemonSocket}
  alias Phoenix.Socket.Message

  @endpoint HelmsmanWeb.Endpoint
  @v HelmsmanProtocol.repo_registration_version()

  setup do
    pid = Sandbox.start_owner!(Repo, shared: true)
    on_exit(fn -> Sandbox.stop_owner(pid) end)

    alice = user_fixture()
    bob = user_fixture()
    workspace = workspace_fixture(alice)
    member_fixture(workspace, bob, :member)
    scope = workspace_scope_fixture(alice, workspace)
    {daemon, token} = daemon_fixture(alice, %{workspace_ids: [workspace.id], name: "alice-mbp"})
    {bob_daemon, bob_token} = daemon_fixture(bob, %{workspace_ids: [workspace.id]})

    %{
      workspace: workspace,
      scope: scope,
      daemon: daemon,
      token: token,
      bob_daemon: bob_daemon,
      bob_token: bob_token
    }
  end

  defp join_report(ctx, protocol, extra \\ %{}) do
    attrs =
      Map.merge(
        %{
          protocol: protocol,
          machine: %{
            machine_id: "m",
            name: "machine",
            os: "linux",
            arch: "x86_64",
            daemon_version: "0.9.0"
          },
          clis: [],
          max_concurrency: 4,
          active_runs: [],
          local_repositories: [],
          repo_registration: if(protocol >= @v, do: true, else: nil)
        },
        extra
      )

    {:ok, value} = Report.Join.new(attrs)
    {:ok, {_name, payload}} = Messages.encode(value, protocol)
    _ = ctx
    payload
  end

  defp joined(ctx, token, daemon, protocol, assigns \\ %{}) do
    {:ok, socket} =
      connect(DaemonSocket, %{},
        connect_info: %{x_headers: [{HelmsmanProtocol.token_header(), token}]}
      )

    socket = Enum.reduce(assigns, socket, fn {k, v}, s -> Phoenix.Socket.assign(s, k, v) end)

    {:ok, _reply, socket} =
      join(socket, DaemonChannel, "daemon:#{daemon.id}", join_report(ctx, protocol))

    socket
  end

  defp alice(ctx, assigns \\ %{}), do: joined(ctx, ctx.token, ctx.daemon, @v, assigns)

  defp request(socket, name, payload) do
    ref = push(socket, name, payload)
    assert_reply ref, status, reply, 5_000

    case status do
      :ok -> {:ok, reply}
      :error -> {:error, elem(ErrorReply.from_wire(reply), 1)}
    end
  end

  defp send_report(socket, module, attrs) do
    {:ok, value} = module.new(attrs)
    {:ok, {name, payload}} = Messages.encode(value, @v)
    request(socket, name, payload)
  end

  defp browse_result(request_id, extra \\ %{}),
    do:
      Map.merge(
        %{
          request_id: request_id,
          error: nil,
          message: nil,
          roots: ["~/secret-root"],
          repositories: [
            %{root: "~/secret-root", path: "hidden/app", name: "app", registered_as: nil}
          ],
          truncated: false
        },
        extra
      )

  defp change_result(request_id, extra \\ %{}),
    do:
      Map.merge(
        %{request_id: request_id, action: :register, name: "app", error: nil, message: nil},
        extra
      )

  # Asks for a browse through the domain and waits for the push on `socket`.
  defp browse(ctx, socket) do
    {:ok, request_id} = WebRegistration.browse(ctx.scope, ctx.daemon.id)
    topic = socket.topic

    assert_receive %Message{
      topic: ^topic,
      event: "repo_browse",
      payload: %{"request_id" => ^request_id}
    }

    request_id
  end

  defp register(ctx, socket) do
    {:ok, request_id} =
      WebRegistration.register(ctx.scope, ctx.daemon.id, %{
        root: "~/code",
        path: "app",
        name: "app",
        workspace_ids: [ctx.workspace.id]
      })

    topic = socket.topic

    assert_receive %Message{
      topic: ^topic,
      event: "repo_register",
      payload: %{"request_id" => ^request_id, "path" => "app", "root" => "~/code"}
    }

    request_id
  end

  defp stopped(socket) do
    Process.unlink(socket.channel_pid)
    Process.monitor(socket.channel_pid)
  end

  defp changes, do: Repo.all(from(c in Change, order_by: c.id))

  describe "requests" do
    test "a protocol 7 connection gets repo_browse, repo_register and repo_remove", ctx do
      socket = alice(ctx)
      browse(ctx, socket)
      request_id = register(ctx, socket)

      assert {:ok, _} = send_report(socket, Report.RepoChangeResult, change_result(request_id))

      repo = local_repository_fixture(ctx.workspace, ctx.daemon, %{name: "lib"})
      {:ok, remove_id} = WebRegistration.remove(ctx.scope, repo.id)
      assert_push "repo_remove", %{"request_id" => ^remove_id, "name" => "lib"}
    end

    test "a protocol 6 connection: daemon_outdated at once, the record fails", ctx do
      socket = joined(ctx, ctx.token, ctx.daemon, @v - 1)
      request_id = "outdated-request-id-000001"

      Repo.insert!(%Change{
        daemon_id: ctx.daemon.id,
        user_id: ctx.daemon.user_id,
        workspace_id: ctx.workspace.id,
        action: "remove",
        name: "app",
        request_id: request_id,
        inserted_at: DateTime.utc_now()
      })

      :ok = Events.subscribe(WebRegistration.topic(request_id))
      daemon_id = ctx.daemon.id

      Events.broadcast(
        Events.topic(:daemon, daemon_id),
        {:local_repo_request, %Push.RepoRemove{request_id: request_id, name: "app"}}
      )

      assert_receive {:local_repo_result, ^request_id, ^daemon_id,
                      {:error, :daemon_outdated, nil}}

      refute_push "repo_remove", _
      assert %Change{status: "failed", error: "daemon_outdated"} = hd(changes())

      browse_id = "outdated-browse-id-000001"
      :ok = Events.subscribe(WebRegistration.topic(browse_id))

      Events.broadcast(
        Events.topic(:daemon, daemon_id),
        {:local_repo_request, %Push.RepoBrowse{request_id: browse_id}}
      )

      assert_receive {:local_repo_result, ^browse_id, ^daemon_id, {:error, :daemon_outdated, nil}}
      assert Process.alive?(socket.channel_pid)
    end

    test "a connection of an old authorization is sent nothing and ends", ctx do
      socket = alice(ctx)
      ref = stopped(socket)
      Repo.update_all(from(d in Daemon, where: d.id == ^ctx.daemon.id), inc: [auth_epoch: 1])

      Events.broadcast(
        Events.topic(:daemon, ctx.daemon.id),
        {:local_repo_request, %Push.RepoBrowse{request_id: "stale-browse-request-0001"}}
      )

      assert_receive {:DOWN, ^ref, :process, _pid, _reason}, 5_000
      refute_push "repo_browse", _
    end
  end

  describe "browse results" do
    test "the connection that was asked, in time: delivered", ctx do
      socket = alice(ctx)
      request_id = browse(ctx, socket)
      daemon_id = ctx.daemon.id

      assert {:ok, %{}} = send_report(socket, Report.RepoBrowseResult, browse_result(request_id))

      assert_receive {:local_repo_result, ^request_id, ^daemon_id,
                      {:ok, %{roots: ["~/secret-root"], repositories: [repo], truncated: false}}}

      assert %{root: "~/secret-root", path: "hidden/app", name: "app", registered_as: nil} =
               Map.take(repo, [:root, :path, :name, :registered_as])

      # A second delivery of the same result is dropped.
      assert {:ok, _} = send_report(socket, Report.RepoBrowseResult, browse_result(request_id))
      refute_receive {:local_repo_result, _, _, _}, 50
    end

    test "dropped results: another daemon, expired, forgotten; nothing stored or logged",
         ctx do
      socket = alice(ctx, %{repo_browse_ttl_ms: 300})
      bob = joined(ctx, ctx.bob_token, ctx.bob_daemon, @v)

      log =
        capture_log([level: :debug], fn ->
          # Another authenticated daemon answers alice's request.
          request_id = browse(ctx, socket)
          assert {:ok, _} = send_report(bob, Report.RepoBrowseResult, browse_result(request_id))
          refute_receive {:local_repo_result, _, _, _}, 50

          # alice-mbp's own answer still counts afterwards (scenario).
          assert {:ok, _} =
                   send_report(socket, Report.RepoBrowseResult, browse_result(request_id))

          assert_receive {:local_repo_result, ^request_id, _, {:ok, _}}

          # Past the deadline.
          late = browse(ctx, socket)
          Process.sleep(350)
          assert {:ok, _} = send_report(socket, Report.RepoBrowseResult, browse_result(late))
          refute_receive {:local_repo_result, _, _, _}, 50

          # The page stopped waiting.
          forgotten = browse(ctx, socket)
          WebRegistration.forget(forgotten)

          assert {:ok, _} =
                   send_report(socket, Report.RepoBrowseResult, browse_result(forgotten))

          refute_receive {:local_repo_result, _, _, _}, 50
        end)

      assert changes() == []
      refute log =~ "secret-root"
      refute log =~ "hidden"
    end

    test "a connection of an old authorization: not delivered, disconnected", ctx do
      socket = alice(ctx)
      request_id = browse(ctx, socket)
      ref = stopped(socket)
      Repo.update_all(from(d in Daemon, where: d.id == ^ctx.daemon.id), inc: [auth_epoch: 1])

      assert {:error, %ErrorReply{reason: :not_found}} =
               send_report(socket, Report.RepoBrowseResult, browse_result(request_id))

      refute_receive {:local_repo_result, _, _, _}, 50
      assert_receive {:DOWN, ^ref, :process, _pid, _reason}, 5_000
    end

    test "at most 16 pending: the oldest is dropped", ctx do
      socket = alice(ctx)
      [oldest, second | _] = for _ <- 1..17, do: browse(ctx, socket)

      assert {:ok, _} = send_report(socket, Report.RepoBrowseResult, browse_result(oldest))
      refute_receive {:local_repo_result, _, _, _}, 50

      assert {:ok, _} = send_report(socket, Report.RepoBrowseResult, browse_result(second))
      assert_receive {:local_repo_result, ^second, _, {:ok, _}}
    end
  end

  describe "change results" do
    test "delivered to the requester and recorded", ctx do
      socket = alice(ctx)
      request_id = register(ctx, socket)
      daemon_id = ctx.daemon.id

      assert {:ok, %{}} = send_report(socket, Report.RepoChangeResult, change_result(request_id))

      assert_receive {:local_repo_result, ^request_id, ^daemon_id,
                      {:ok, %{action: :register, name: "app"}}}

      assert [%Change{status: "succeeded", completed_at: %DateTime{}}] = changes()

      # Written once.
      assert {:ok, _} =
               send_report(
                 socket,
                 Report.RepoChangeResult,
                 change_result(request_id, %{error: :busy})
               )

      refute_receive {:local_repo_result, _, _, _}, 50
      assert [%Change{status: "succeeded", error: nil}] = changes()
    end

    test "another daemon's result, or another action or name, is ignored (scenario)", ctx do
      socket = alice(ctx)
      bob = joined(ctx, ctx.bob_token, ctx.bob_daemon, @v)
      request_id = register(ctx, socket)

      assert {:ok, _} = send_report(bob, Report.RepoChangeResult, change_result(request_id))

      assert {:ok, _} =
               send_report(
                 socket,
                 Report.RepoChangeResult,
                 change_result(request_id, %{action: :remove})
               )

      assert {:ok, _} =
               send_report(
                 socket,
                 Report.RepoChangeResult,
                 change_result(request_id, %{name: "lib"})
               )

      refute_receive {:local_repo_result, _, _, _}, 50
      assert [%Change{status: "pending"}] = changes()

      assert {:ok, _} = send_report(socket, Report.RepoChangeResult, change_result(request_id))
      assert_receive {:local_repo_result, ^request_id, _, {:ok, _}}
    end

    test "an old authorization: not_found and the connection ends", ctx do
      socket = alice(ctx)
      request_id = register(ctx, socket)
      ref = stopped(socket)
      Repo.update_all(from(d in Daemon, where: d.id == ^ctx.daemon.id), inc: [auth_epoch: 1])

      assert {:error, %ErrorReply{reason: :not_found}} =
               send_report(socket, Report.RepoChangeResult, change_result(request_id))

      assert_receive {:DOWN, ^ref, :process, _pid, _reason}, 5_000
      assert [%Change{status: "pending"}] = changes()
    end

    test "the sync sent first has updated the rows when the result arrives", ctx do
      socket = alice(ctx)
      request_id = register(ctx, socket)
      :ok = Events.subscribe(Events.topic(:workspace, ctx.workspace.id))

      {:ok, sync} =
        Report.Sync.new(%{
          machine: %{
            machine_id: "m",
            name: "machine",
            os: "linux",
            arch: "x86_64",
            daemon_version: "0.9.0"
          },
          clis: [],
          max_concurrency: 4,
          local_repositories: [Map.from_struct(local_report("app", [ctx.workspace.id]))],
          repo_registration: true
        })

      {:ok, {"sync", payload}} = Messages.encode(sync, @v)
      assert {:ok, _} = request(socket, "sync", payload)
      assert {:ok, _} = send_report(socket, Report.RepoChangeResult, change_result(request_id))

      # Both were broadcast before their replies, in this order.
      {:messages, messages} = Process.info(self(), :messages)

      assert [{:local_repositories_changed}, {:local_repo_result, ^request_id, _, {:ok, _}} | _] =
               Enum.filter(messages, fn
                 {:local_repositories_changed} -> true
                 {:local_repo_result, _, _, _} -> true
                 _other -> false
               end)

      assert Repo.get_by!(LocalRepository, daemon_id: ctx.daemon.id, name: "app").status ==
               "online"
    end
  end

  test "a protocol 6 connection's results are invalid_payload (scenario)", ctx do
    socket = joined(ctx, ctx.token, ctx.daemon, @v - 1)

    for {module, attrs} <- [
          {Report.RepoBrowseResult, browse_result("old-connection-request-01")},
          {Report.RepoChangeResult, change_result("old-connection-request-01")}
        ] do
      assert {:error, %ErrorReply{reason: :invalid_payload}} = send_report(socket, module, attrs)
    end
  end

  test "a protocol 6 sync cannot allow web registration", ctx do
    socket = joined(ctx, ctx.token, ctx.daemon, @v - 1)
    {:ok, sync} = Messages.encode(elem(Report.Sync.new(sync_attrs(true)), 1), @v)
    {"sync", payload} = sync
    assert {:ok, _} = request(socket, "sync", payload)
    refute Repo.get!(Daemon, ctx.daemon.id).repo_registration
  end

  defp sync_attrs(value),
    do: %{
      machine: %{
        machine_id: "m",
        name: "machine",
        os: "linux",
        arch: "x86_64",
        daemon_version: "0.9.0"
      },
      clis: [],
      max_concurrency: 4,
      local_repositories: [],
      repo_registration: value
    }
end
