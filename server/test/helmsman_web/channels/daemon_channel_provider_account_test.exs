defmodule HelmsmanWeb.DaemonChannelProviderAccountTest do
  # add-provider-accounts 3.4: the claim over the daemon channel honours
  # the connection's protocol version (decision 4).
  use ExUnit.Case, async: false

  import Phoenix.ChannelTest
  import Helmsman.AccountsFixtures
  import Helmsman.AgentsFixtures
  import Helmsman.ProviderAccountsFixtures
  import Helmsman.RunsFixtures
  import Helmsman.WorkspacesFixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias Helmsman.Repo
  alias Helmsman.Runs.Run
  alias HelmsmanProtocol.{Messages, Report}
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
    zai = provider_account_fixture(alice, %{name: "zai", api_key: "sk-zai-1"})
    managed_agent_fixture(scope, %{name: "keel/dev", runtime_id: runtime.id})

    managed_agent_fixture(scope, %{
      name: "keel/zai",
      runtime_id: runtime.id,
      provider_account_id: zai.id
    })

    plain = run_fixture(agent_actor(workspace, "keel/dev"))
    bound = run_fixture(agent_actor(workspace, "keel/zai"))
    %{daemon: daemon, token: token, plain: plain, bound: bound}
  end

  defp join_payload(daemon, protocol) do
    {:ok, report} =
      Report.Join.new(%{
        protocol: HelmsmanProtocol.version(),
        machine: %{
          machine_id: daemon.machine_id,
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

    {:ok, {_name, payload}} = Messages.encode(report)
    Map.put(payload, "protocol", protocol)
  end

  # The raw claim reply, as the daemon receives it.
  defp claim(ctx, protocol) do
    {:ok, socket} =
      connect(DaemonSocket, %{},
        connect_info: %{x_headers: [{HelmsmanProtocol.token_header(), ctx.token}]}
      )

    {:ok, _reply, socket} =
      join(socket, DaemonChannel, "daemon:#{ctx.daemon.id}", join_payload(ctx.daemon, protocol))

    {:ok, {_name, payload}} = Messages.encode(%Report.Claim{})
    ref = push(socket, "claim", payload)
    assert_reply ref, :ok, reply, 5_000
    reply["runs"]
  end

  defp status(run), do: Repo.get!(Run, run.id).status

  test "an older connection claims only the runs without an account (scenario)", ctx do
    old = HelmsmanProtocol.provider_account_version() - 1
    assert [run] = claim(ctx, old)

    assert run["run_id"] == ctx.plain.id
    refute Map.has_key?(run["agent"], "provider_account")
    refute inspect(run) =~ "sk-zai-1"
    assert status(ctx.bound) == :queued
  end

  test "a current connection claims both, with the account in the description", ctx do
    runs = claim(ctx, HelmsmanProtocol.provider_account_version())
    by_id = Map.new(runs, &{&1["run_id"], &1})

    assert by_id[ctx.plain.id]["agent"]["provider_account"] == nil

    assert %{
             "base_url" => "https://api.z.ai/api/anthropic",
             "api_key" => "sk-zai-1",
             "models" => %{"default" => "glm-5.3"}
           } = by_id[ctx.bound.id]["agent"]["provider_account"]

    assert status(ctx.bound) == :claimed
  end
end
