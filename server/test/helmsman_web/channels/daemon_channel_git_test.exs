defmodule HelmsmanWeb.DaemonChannelGitTest do
  # add-daemon-git-workspace 1.4, 1.5: `claim` with a repository, `git_token`
  # and `pushed` on the daemon channel (decision 7). Payloads are encoded
  # and replies decoded with `HelmsmanProtocol.Messages`, as the daemon
  # does.
  use ExUnit.Case, async: false

  @moduletag :capture_log

  import Phoenix.ChannelTest
  import Ecto.Query, only: [from: 2]
  import Helmsman.AccountsFixtures
  import Helmsman.AgentsFixtures
  import Helmsman.GitHubFixtures
  import Helmsman.ProjectsFixtures
  import Helmsman.RunsFixtures
  import Helmsman.WorkspacesFixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias Helmsman.Daemons.Daemon
  alias Helmsman.GitHub.{Installation, Tokens}
  alias Helmsman.Repo
  alias Helmsman.Runs.Run
  alias HelmsmanProtocol.{ErrorReply, Messages, Reply, Report, RunSpec}
  alias HelmsmanWeb.{DaemonChannel, DaemonSocket}

  @endpoint HelmsmanWeb.Endpoint

  setup do
    pid = Sandbox.start_owner!(Repo, shared: true)
    on_exit(fn -> Sandbox.stop_owner(pid) end)

    alice = user_fixture()
    workspace = workspace_fixture(alice)
    scope = workspace_scope_fixture(alice, workspace)
    {daemon, token} = daemon_fixture(alice, %{workspace_ids: [workspace.id]})
    runtime = runtime_fixture(workspace, daemon)
    managed_agent_fixture(scope, %{name: "keel/dev", runtime_id: runtime.id})
    project = project_fixture(scope)
    installation = installation_fixture(workspace)
    repository = repository_fixture(installation, %{owner: "acme", name: "app"})
    bind_repository(project, repository)
    task = task_fixture(scope, project.key, %{assignee: "keel/dev"})
    [run] = runs_of(task.id)

    %{
      workspace: workspace,
      daemon: daemon,
      token: token,
      task: task,
      run: run,
      repository: repository,
      branch: "hm/#{workspace.id}/#{String.downcase(task.ident)}"
    }
  end

  defp new!(module, attrs) do
    {:ok, value} = module.new(attrs)
    value
  end

  defp joined(ctx) do
    {:ok, socket} =
      connect(DaemonSocket, %{},
        connect_info: %{x_headers: [{HelmsmanProtocol.token_header(), ctx.token}]}
      )

    join_payload =
      Report.Join
      |> new!(%{
        protocol: HelmsmanProtocol.version(),
        machine: %{
          machine_id: ctx.daemon.machine_id,
          name: "alice-laptop",
          os: "linux",
          arch: "x86_64",
          daemon_version: "0.2.0"
        },
        clis: [
          %{
            provider: :claude,
            version: "2.0.0",
            models: [],
            efforts: [],
            available: true,
            unavailable_reason: nil
          }
        ],
        max_concurrency: 4,
        active_runs: []
      })
      |> encode!()

    {:ok, _reply, socket} =
      join(socket, DaemonChannel, "daemon:#{ctx.daemon.id}", join_payload)

    socket
  end

  defp encode!(struct) do
    {:ok, {_name, payload}} = Messages.encode(struct)
    payload
  end

  # The decoded reply and the raw payload.
  defp request(socket, name, struct) do
    ref = push(socket, name, encode!(struct))
    assert_reply ref, status, payload, 5_000

    case status do
      :ok ->
        assert {:ok, reply} = Messages.decode_reply(name, payload)
        {:ok, reply, payload}

      :error ->
        assert {:ok, %ErrorReply{} = error} = ErrorReply.from_wire(payload)
        {:error, error}
    end
  end

  defp pushed(ctx, attrs \\ %{}) do
    new!(
      Report.Pushed,
      Map.merge(
        %{
          run_id: ctx.run.id,
          branch: ctx.branch,
          base_sha: String.duplicate("0", 40),
          head_sha: String.duplicate("a", 40),
          commits: [%{sha: String.duplicate("a", 40), subject: "change"}],
          rescue_branch: nil
        },
        attrs
      )
    )
  end

  defp claimed(ctx) do
    socket = joined(ctx)
    assert {:ok, %Reply.Claim{runs: [spec]}, _} = request(socket, "claim", %Report.Claim{})
    {socket, spec}
  end

  defp reload(run), do: Repo.get!(Run, run.id)

  test "claim prefetches the push token outside the transaction", ctx do
    stub_push_tokens()
    {_socket, spec} = claimed(ctx)

    assert %RunSpec.Repo{branch: branch, git_token: "ghs_push_1"} = spec.repo
    assert branch == ctx.branch
    assert spec.repo.github_repository_id == ctx.repository.github_id
    refute_received :http_in_transaction
    assert %Run{status: :claimed, repository_id: id} = reload(ctx.run)
    assert id == ctx.repository.id
  end

  test "claim leaves the run queued when GitHub is unavailable", ctx do
    stub_push_tokens(fail: :all)
    socket = joined(ctx)

    assert {:ok, %Reply.Claim{runs: []}, _} = request(socket, "claim", %Report.Claim{})
    assert reload(ctx.run).status == :queued
  end

  test "git_token replies the token as the protocol encodes it", ctx do
    stub_push_tokens()
    {socket, _spec} = claimed(ctx)

    assert {:ok, %Reply.GitToken{token: "ghs_push_1", expires_at: %DateTime{}} = reply, payload} =
             request(socket, "git_token", %Report.GitToken{run_id: ctx.run.id})

    assert {:ok, ^payload} = Messages.encode_reply("git_token", reply)
    refute_received :http_in_transaction
  end

  test "git_token errors: wrong_state with the reason, the channel stays", ctx do
    stub_push_tokens()
    {socket, _spec} = claimed(ctx)
    stub_push_tokens(fail: :all)
    Tokens.purge(installation_id(ctx))

    assert {:error,
            %ErrorReply{reason: :wrong_state, message: "GitHub is unavailable, retry later"}} =
             request(socket, "git_token", %Report.GitToken{run_id: ctx.run.id})

    Repo.update_all(from(r in Run, where: r.id == ^ctx.run.id),
      set: [status: :failed, finished_at: DateTime.add(DateTime.utc_now(), -31 * 60, :second)]
    )

    assert {:error, %ErrorReply{reason: :wrong_state}} =
             request(socket, "git_token", %Report.GitToken{run_id: ctx.run.id})

    assert {:error, %ErrorReply{reason: :not_found}} =
             request(socket, "git_token", %Report.GitToken{run_id: ctx.run.id + 1_000_000})

    assert Process.alive?(socket.channel_pid)
  end

  test "pushed: Empty, invalid_payload, wrong_state", ctx do
    stub_push_tokens()
    {socket, _spec} = claimed(ctx)

    assert {:ok, %Reply.Empty{}, payload} = request(socket, "pushed", pushed(ctx))
    assert {:ok, ^payload} = Messages.encode_reply("pushed", %Reply.Empty{})
    assert %Run{push_status: :pushed} = reload(ctx.run)

    assert {:ok, %Reply.Empty{}, _} = request(socket, "pushed", pushed(ctx))

    assert {:error, %ErrorReply{reason: :invalid_payload}} =
             request(socket, "pushed", pushed(ctx, %{branch: "hm/0/other"}))

    assert {:error, %ErrorReply{reason: :wrong_state}} =
             request(socket, "pushed", pushed(ctx, %{head_sha: String.duplicate("b", 40)}))

    assert Process.alive?(socket.channel_pid)
  end

  for name <- ["git_token", "pushed"] do
    test "an old epoch: #{name} is not_found and disconnects", ctx do
      stub_push_tokens()
      {socket, _spec} = claimed(ctx)
      Repo.update_all(from(d in Daemon, where: d.id == ^ctx.daemon.id), inc: [auth_epoch: 1])
      monitor = Process.monitor(socket.channel_pid)

      report =
        if unquote(name) == "pushed",
          do: pushed(ctx),
          else: %Report.GitToken{run_id: ctx.run.id}

      assert {:error, %ErrorReply{reason: :not_found}} = request(socket, unquote(name), report)
      pid = socket.channel_pid
      assert_receive {:DOWN, ^monitor, :process, ^pid, _reason}
      assert reload(ctx.run).pushed_at == nil
    end
  end

  defp installation_id(ctx) do
    Repo.one!(
      from(i in Installation,
        where: i.id == ^ctx.repository.installation_id,
        select: i.installation_id
      )
    )
  end
end
