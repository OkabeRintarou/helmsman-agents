defmodule HelmsmanWeb.DaemonChannelLocalTest do
  # add-local-repositories 2.7: local repositories on the daemon channel —
  # join / sync replies by the connection's protocol version and
  # `repo_status` (decision 13). Payloads are encoded and replies decoded
  # with `HelmsmanProtocol.Messages`, as the daemon does.
  use ExUnit.Case, async: false

  @moduletag :capture_log

  import Phoenix.ChannelTest
  import Ecto.Query, only: [from: 2]
  import Helmsman.AccountsFixtures
  import Helmsman.AgentsFixtures
  import Helmsman.LocalRepositoriesFixtures
  import Helmsman.ProjectsFixtures
  import Helmsman.WorkspacesFixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias Helmsman.Daemons.Daemon
  alias Helmsman.LocalRepositories.{LocalRepository, TaskLocalBranch}
  alias Helmsman.Repo
  alias HelmsmanProtocol.{ErrorReply, Messages, Reply, Report}
  alias HelmsmanWeb.{DaemonChannel, DaemonSocket}

  @endpoint HelmsmanWeb.Endpoint
  @v HelmsmanProtocol.local_repositories_version()

  setup do
    pid = Sandbox.start_owner!(Repo, shared: true)
    on_exit(fn -> Sandbox.stop_owner(pid) end)

    alice = user_fixture()
    workspace = workspace_fixture(alice)
    scope = workspace_scope_fixture(alice, workspace)
    {daemon, token} = daemon_fixture(alice, %{workspace_ids: [workspace.id]})
    %{workspace: workspace, scope: scope, daemon: daemon, token: token}
  end

  defp machine(ctx) do
    %{
      machine_id: ctx.daemon.machine_id,
      name: "alice-laptop",
      os: "linux",
      arch: "x86_64",
      daemon_version: "0.3.0"
    }
  end

  defp report(ctx, module, protocol) do
    attrs = %{
      machine: machine(ctx),
      clis: [],
      max_concurrency: 4,
      local_repositories:
        if(protocol >= @v, do: [local_report("app", [ctx.workspace.id])], else: nil)
    }

    attrs =
      if module == Report.Join,
        do: Map.merge(attrs, %{protocol: protocol, active_runs: []}),
        else: attrs

    {:ok, value} = module.new(attrs)
    {:ok, {_name, payload}} = Messages.encode(value, protocol)
    payload
  end

  defp joined(ctx, protocol) do
    {:ok, socket} =
      connect(DaemonSocket, %{},
        connect_info: %{x_headers: [{HelmsmanProtocol.token_header(), ctx.token}]}
      )

    {:ok, reply, socket} =
      join(socket, DaemonChannel, "daemon:#{ctx.daemon.id}", report(ctx, Report.Join, protocol))

    {socket, reply}
  end

  defp request(socket, name, payload) do
    ref = push(socket, name, payload)
    assert_reply ref, status, reply, 5_000

    case status do
      :ok -> {:ok, reply}
      :error -> {:error, elem(ErrorReply.from_wire(reply), 1)}
    end
  end

  test "protocol 1 and 2 connections get no local repositories and cannot send repo_status",
       ctx do
    local_repository_fixture(ctx.workspace, ctx.daemon)

    for protocol <- 1..(@v - 1) do
      {socket, reply} = joined(ctx, protocol)
      refute Map.has_key?(reply, "local_repositories")
      assert {:ok, %Reply.Join{local_repositories: nil}} = Messages.decode_reply("join", reply)

      assert {:ok, sync_reply} = request(socket, "sync", report(ctx, Report.Sync, protocol))
      refute Map.has_key?(sync_reply, "local_repositories")

      status = %{"workspace_id" => ctx.workspace.id, "name" => "app", "results" => []}

      assert {:error, %ErrorReply{reason: :invalid_payload}} =
               request(socket, "repo_status", status)

      # A field the connection's version does not have is ignored.
      sync = Map.put(report(ctx, Report.Sync, protocol), "local_repositories", [])
      assert {:ok, _} = request(socket, "sync", sync)
      assert Repo.get_by!(LocalRepository, daemon_id: ctx.daemon.id).status == "online"
      Process.unlink(socket.channel_pid)
      close(socket)
    end
  end

  test "protocol 3: join registers and replies with the watch list; repo_status roundtrip",
       ctx do
    {socket, reply} = joined(ctx, @v)
    repo = Repo.get_by!(LocalRepository, daemon_id: ctx.daemon.id, name: "app")
    workspace_id = ctx.workspace.id
    repo_id = repo.id

    assert {:ok, %Reply.Join{local_repositories: [entry]}} = Messages.decode_reply("join", reply)

    assert %Reply.Join.LocalRepository{
             workspace_id: ^workspace_id,
             name: "app",
             local_repository_id: ^repo_id,
             watch: []
           } = entry

    project = bind_local(project_fixture(ctx.scope), repo)
    task = task_fixture(ctx.scope, project.key)
    branch = "hm/#{ctx.workspace.id}/#{String.downcase(task.ident)}"
    head = String.duplicate("c", 40)

    Repo.insert!(%TaskLocalBranch{
      workspace_id: ctx.workspace.id,
      task_id: task.id,
      local_repository_id: repo.id,
      branch: branch,
      head_sha: head
    })

    assert {:ok, sync_reply} = request(socket, "sync", report(ctx, Report.Sync, @v))

    assert {:ok, %Reply.Join{local_repositories: [%{watch: [watch]}]}} =
             Messages.decode_reply("sync", sync_reply)

    assert %{branch: ^branch, head_sha: ^head, base_branch: "main"} = watch

    {:ok, status} =
      Report.RepoStatus.new(%{
        workspace_id: ctx.workspace.id,
        name: "app",
        results: [%{branch: branch, head_sha: head, merged: :yes}]
      })

    {:ok, {"repo_status", payload}} = Messages.encode(status, @v)
    assert {:ok, empty} = request(socket, "repo_status", payload)
    assert {:ok, %Reply.Empty{}} = Messages.decode_reply("repo_status", empty)
    assert Repo.get_by!(TaskLocalBranch, task_id: task.id).state == "merged"

    unknown = Map.put(payload, "name", "nope")
    assert {:error, %ErrorReply{reason: :not_found}} = request(socket, "repo_status", unknown)

    bad = put_in(payload, ["results", Access.at(0), "merged"], "maybe")
    assert {:error, %ErrorReply{reason: :invalid_payload}} = request(socket, "repo_status", bad)
  end

  test "repo_status in an old authorization: not_found and the connection ends", ctx do
    {socket, _reply} = joined(ctx, @v)
    Process.unlink(socket.channel_pid)
    ref = Process.monitor(socket.channel_pid)

    Repo.update_all(from(d in Daemon, where: d.id == ^ctx.daemon.id), inc: [auth_epoch: 1])
    payload = %{"workspace_id" => ctx.workspace.id, "name" => "app", "results" => []}

    assert {:error, %ErrorReply{reason: :not_found}} = request(socket, "repo_status", payload)
    assert_receive {:DOWN, ^ref, :process, _pid, _reason}, 5_000
  end
end
