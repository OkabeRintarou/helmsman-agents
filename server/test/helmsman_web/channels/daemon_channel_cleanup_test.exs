defmodule HelmsmanWeb.DaemonChannelCleanupTest do
  # add-pr-reconcile-merge 1.10: `cleanup_check` on the daemon channel
  # (decision 16): answered from protocol Vc (`cleanup_version/0`), refused
  # with `unsupported_protocol` below it. Payloads are encoded and replies
  # decoded with `HelmsmanProtocol.Messages`, as the daemon does.
  use ExUnit.Case, async: false

  @moduletag :capture_log

  import Phoenix.ChannelTest
  import Ecto.Query, only: [from: 2]
  import Helmsman.AccountsFixtures
  import Helmsman.AgentsFixtures
  import Helmsman.ProjectsFixtures
  import Helmsman.WorkspacesFixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias Helmsman.Daemons.Daemon
  alias Helmsman.Repo
  alias Helmsman.Tasks.Task
  alias HelmsmanProtocol.{CleanupItem, CleanupResult, ErrorReply, Messages, Reply, Report}
  alias HelmsmanWeb.{DaemonChannel, DaemonSocket}

  @endpoint HelmsmanWeb.Endpoint
  @vc HelmsmanProtocol.cleanup_version()

  setup do
    pid = Sandbox.start_owner!(Repo, shared: true)
    on_exit(fn -> Sandbox.stop_owner(pid) end)

    alice = user_fixture()
    workspace = workspace_fixture(alice)
    scope = workspace_scope_fixture(alice, workspace)
    {daemon, token} = daemon_fixture(alice, %{workspace_ids: [workspace.id]})
    project = project_fixture(scope)
    task = task_fixture(scope, project.key)
    Repo.update_all(from(t in Task, where: t.id == ^task.id), set: [status: :cancelled])
    %{workspace: workspace, daemon: daemon, token: token, task: task}
  end

  defp joined(ctx, protocol) do
    {:ok, join} =
      Report.Join.new(%{
        protocol: protocol,
        machine: %{
          machine_id: ctx.daemon.machine_id,
          name: "alice-laptop",
          os: "linux",
          arch: "x86_64",
          daemon_version: "0.4.0"
        },
        clis: [],
        max_concurrency: 4,
        active_runs: []
      })

    {:ok, {_name, payload}} = Messages.encode(join, protocol)

    {:ok, socket} =
      connect(DaemonSocket, %{},
        connect_info: %{x_headers: [{HelmsmanProtocol.token_header(), ctx.token}]}
      )

    {:ok, _reply, socket} = join(socket, DaemonChannel, "daemon:#{ctx.daemon.id}", payload)
    socket
  end

  defp request(socket, payload) do
    ref = push(socket, "cleanup_check", payload)
    assert_reply ref, status, reply, 5_000

    case status do
      :ok -> Messages.decode_reply("cleanup_check", reply)
      :error -> {:error, elem(ErrorReply.from_wire(reply), 1)}
    end
  end

  defp items(ctx, idents) do
    Enum.map(idents, &%CleanupItem{workspace_id: ctx.workspace.id, ident: &1})
  end

  test "protocol Vc: one result per item, the ident as sent", ctx do
    socket = joined(ctx, @vc)
    lower = String.downcase(ctx.task.ident)

    {:ok, {"cleanup_check", payload}} =
      Messages.encode(%Report.CleanupCheck{items: items(ctx, [lower, "NOPE-1"])}, @vc)

    assert {:ok, %Reply.CleanupCheck{results: [mine, unknown]}} = request(socket, payload)

    assert %CleanupResult{ident: ^lower, deletable: true, base_branch: nil, pushed_heads: []} =
             mine

    assert %CleanupResult{ident: "NOPE-1", deletable: false} = unknown
  end

  test "below Vc the message is refused with unsupported_protocol", ctx do
    payload = %{
      "items" => [%{"workspace_id" => ctx.workspace.id, "ident" => ctx.task.ident}]
    }

    for protocol <- [1, @vc - 1] do
      socket = joined(ctx, protocol)

      assert {:error, %ErrorReply{reason: :unsupported_protocol}} = request(socket, payload)

      Process.unlink(socket.channel_pid)
      close(socket)
    end
  end

  test "a reauthorized daemon is disconnected", ctx do
    socket = joined(ctx, @vc)
    Process.unlink(socket.channel_pid)

    Repo.update_all(from(d in Daemon, where: d.id == ^ctx.daemon.id),
      inc: [auth_epoch: 1]
    )

    {:ok, {"cleanup_check", payload}} =
      Messages.encode(%Report.CleanupCheck{items: items(ctx, [ctx.task.ident])}, @vc)

    assert {:error, %ErrorReply{reason: :not_found}} = request(socket, payload)
  end
end
