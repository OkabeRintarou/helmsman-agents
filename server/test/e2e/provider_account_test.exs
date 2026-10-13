defmodule Helmsman.E2E.ProviderAccountTest do
  # add-provider-accounts 5.1: the account survives the server claim protocol,
  # is injected into the matching Claude process, and remains protocol-gated.
  use ExUnit.Case, async: false

  @moduletag :e2e
  @moduletag timeout: 300_000

  import Phoenix.ChannelTest
  import Helmsman.AccountsFixtures
  import Helmsman.AgentsFixtures
  import Helmsman.ProviderAccountsFixtures
  import Helmsman.RunsFixtures
  import Helmsman.WorkspacesFixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias Helmsman.Accounts.Scope
  alias Helmsman.{CommittedData, DaemonE2E, ProviderAccounts, Repo}
  alias Helmsman.Daemons.Runtime
  alias Helmsman.Runs
  alias Helmsman.Runs.Run
  alias HelmsmanProtocol.{Messages, Report}
  alias HelmsmanWeb.{DaemonChannel, DaemonSocket}

  @endpoint HelmsmanWeb.Endpoint
  @provider_cli Path.expand("../support/fake_cli/provider-account-claude", __DIR__)

  setup do
    :ok = Sandbox.mode(Repo, :auto)
    on_exit(fn -> Sandbox.mode(Repo, :manual) end)

    tag = Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
    home = Path.join(System.tmp_dir!(), "helmsman-provider-e2e-#{tag}")
    bin = Path.join(home, "bin")
    File.mkdir_p!(bin)
    File.ln!(@provider_cli, Path.join(bin, "claude"))
    on_exit(fn -> File.rm_rf!(home) end)

    {owner, workspace, scope, daemon, token, runtime, account_a, account_b, agent_a, agent_b} =
      CommittedData.unboxed(fn ->
        owner = user_fixture(%{email: "provider-e2e-#{tag}@test.invalid"})
        workspace = workspace_fixture(owner, %{slug: "provider-e2e-#{tag}"})
        scope = workspace_scope_fixture(owner, workspace)
        {daemon, token} = daemon_fixture(owner, %{workspace_ids: [workspace.id]})
        runtime = runtime_fixture(workspace, daemon)

        account_a =
          provider_account_fixture(owner, %{
            name: "zai-e2e",
            api_key: "ACCOUNT_A_KEY_v1_#{tag}",
            base_url: "https://api.z.ai/api/anthropic"
          })

        account_b =
          provider_account_fixture(owner, %{
            name: "local-e2e",
            api_key: "ACCOUNT_B_KEY_#{tag}",
            base_url: "http://127.0.0.1:9/account-b"
          })

        agent_a =
          managed_agent_fixture(scope, %{
            name: "keel/provider-a",
            runtime_id: runtime.id,
            provider_account_id: account_a.id
          })

        agent_b =
          managed_agent_fixture(scope, %{
            name: "keel/provider-b",
            runtime_id: runtime.id,
            provider_account_id: account_b.id
          })

        {owner, workspace, scope, daemon, token, runtime, account_a, account_b, agent_a, agent_b}
      end)

    endpoint_url = DaemonE2E.start_endpoint()
    on_exit(fn -> CommittedData.delete_user_data!([owner.id]) end)

    %{
      tag: tag,
      home: home,
      bin: bin,
      owner: owner,
      workspace: workspace,
      scope: scope,
      daemon: daemon,
      token: token,
      runtime: runtime,
      account_a: account_a,
      account_b: account_b,
      agent_a: agent_a,
      agent_b: agent_b,
      endpoint_url: endpoint_url
    }
  end

  test "two bound accounts reach only their own CLI run and rotated key is used next time", ctx do
    credentials_home = Path.join(ctx.home, "daemon-home")
    File.mkdir_p!(credentials_home)
    DaemonE2E.write_credentials(credentials_home, ctx.endpoint_url, ctx.daemon.id, ctx.token)

    path = "#{ctx.bin}:#{System.get_env("PATH", "")}" |> String.to_charlist()

    daemon =
      DaemonE2E.start_provider_daemon(credentials_home, [
        {~c"PATH", path},
        {~c"HOME", String.to_charlist(credentials_home)}
      ])

    DaemonE2E.wait_until(
      daemon,
      "provider-account daemon runtime online",
      fn -> Repo.get(Runtime, ctx.runtime.id).status == "online" end
    )

    run_a = run_fixture(agent_actor(ctx.workspace, "keel/provider-a"))
    run_b = run_fixture(agent_actor(ctx.workspace, "keel/provider-b"))

    await_success(daemon, run_a.id)
    await_success(daemon, run_b.id)

    event_a = cli_event(ctx.scope, run_a.id)
    event_b = cli_event(ctx.scope, run_b.id)
    hash_a_v1 = key_hash("ACCOUNT_A_KEY_v1_#{ctx.tag}")
    hash_b = key_hash("ACCOUNT_B_KEY_#{ctx.tag}")

    assert event_a =~ "key_present=true"
    assert event_a =~ "key_sha256=#{hash_a_v1}"
    assert field(event_a, "settings") == settings_path(credentials_home, run_a.id)
    assert field(event_a, "settings_base_url") == ctx.account_a.base_url
    assert event_a =~ "api_key_helper=printenv HELMSMAN_PROVIDER_API_KEY"
    assert event_a =~ "settings_exists=true"

    assert event_b =~ "key_present=true"
    assert event_b =~ "key_sha256=#{hash_b}"
    assert field(event_b, "settings") == settings_path(credentials_home, run_b.id)
    assert field(event_b, "settings_base_url") == ctx.account_b.base_url
    assert event_b =~ "api_key_helper=printenv HELMSMAN_PROVIDER_API_KEY"
    assert event_b =~ "settings_exists=true"

    refute field(event_a, "settings") == field(event_b, "settings")

    assert {:ok, _account} =
             ProviderAccounts.update(
               Scope.for_user(ctx.owner),
               ctx.account_a.id,
               %{api_key: "ACCOUNT_A_KEY_v2_#{ctx.tag}"}
             )

    run_a_v2 = run_fixture(agent_actor(ctx.workspace, "keel/provider-a"))
    await_success(daemon, run_a_v2.id)
    event_a_v2 = cli_event(ctx.scope, run_a_v2.id)

    assert event_a_v2 =~ "key_present=true"
    assert event_a_v2 =~ "key_sha256=#{key_hash("ACCOUNT_A_KEY_v2_#{ctx.tag}")}"
    assert field(event_a_v2, "settings") == settings_path(credentials_home, run_a_v2.id)
    assert field(event_a_v2, "settings_base_url") == ctx.account_a.base_url
    assert event_a_v2 =~ "api_key_helper=printenv HELMSMAN_PROVIDER_API_KEY"
    refute event_a_v2 =~ "key_sha256=#{hash_a_v1}"
  end

  test "a protocol 1 daemon connection leaves an account-bound run queued", ctx do
    run = run_fixture(agent_actor(ctx.workspace, "keel/provider-a"))

    {:ok, socket} =
      connect(DaemonSocket, %{},
        connect_info: %{x_headers: [{HelmsmanProtocol.token_header(), ctx.token}]}
      )

    {:ok, _join_reply, socket} =
      join(socket, DaemonChannel, "daemon:#{ctx.daemon.id}", join_payload(ctx.daemon, 1))

    {:ok, {_event, payload}} = Messages.encode(%Report.Claim{})
    ref = push(socket, "claim", payload)
    assert_reply ref, :ok, %{"runs" => []}, 5_000
    assert Repo.get!(Run, run.id).status == :queued
  end

  defp join_payload(daemon, protocol) do
    {:ok, report} =
      Report.Join.new(%{
        protocol: HelmsmanProtocol.version(),
        machine: %{
          machine_id: daemon.machine_id,
          name: "provider-e2e-old-daemon",
          os: "linux",
          arch: "x86_64",
          daemon_version: "0.2.0"
        },
        clis: [
          %{
            provider: :claude,
            version: "2.1.99",
            models: [],
            efforts: [],
            available: true,
            unavailable_reason: nil
          }
        ],
        max_concurrency: 1,
        active_runs: []
      })

    {:ok, {_event, payload}} = Messages.encode(report)
    Map.put(payload, "protocol", protocol)
  end

  defp await_success(daemon, run_id) do
    assert :ok =
             DaemonE2E.wait_until(
               daemon,
               "run #{run_id} to succeed",
               fn ->
                 case Repo.get(Run, run_id) do
                   %Run{status: :succeeded} -> :ok
                   _ -> false
                 end
               end,
               120_000
             )
  end

  defp cli_event(scope, run_id) do
    assert {:ok, %{events: events}} = Runs.list_events(scope, run_id)

    events
    |> Enum.find_value(fn
      %{type: "text", data: %{"text" => "key_present=" <> _ = text}} -> text
      _ -> nil
    end)
    |> then(&assert(is_binary(&1) && &1))
  end

  defp settings_path(home, run_id),
    do: Path.join([home, "runs", Integer.to_string(run_id), "claude-settings.json"])

  defp field(text, name) do
    case Regex.run(~r/(?:^|\s)#{Regex.escape(name)}=([^\s]+)/, text) do
      [_, value] -> value
      _ -> nil
    end
  end

  defp key_hash(value) do
    value
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
    |> String.slice(0, 8)
  end
end
