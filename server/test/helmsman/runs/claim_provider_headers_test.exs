defmodule Helmsman.Runs.ClaimProviderHeadersTest do
  use Helmsman.DataCase, async: true
  import Helmsman.AgentsFixtures
  import Helmsman.ProviderAccountsFixtures
  import Helmsman.RunsFixtures
  alias Helmsman.Accounts.Scope
  alias Helmsman.{Agents, Dispatch, ProviderAccounts, Runs}
  alias Helmsman.Daemons.Daemon
  alias Helmsman.Runs.Run
  alias HelmsmanProtocol.{Messages, Reply}

  setup do
    ctx = dispatch_fixture()
    daemon = daemon_of(ctx.agent)

    Repo.update_all(from(d in Daemon, where: d.id == ^daemon.id),
      set: [max_concurrency: 8, protocol_version: 4]
    )

    runtime = runtime_fixture(ctx.workspace, daemon, %{provider: "codex"})

    account =
      provider_account_fixture(ctx.alice, %{
        cli: "codex",
        headers: %{
          "user" => "header-one-sentinel",
          "Ocp-Apim-Subscription-Key" => "header-two-sentinel"
        }
      })

    managed_agent_fixture(ctx.alice_scope, %{
      name: "keel/headers",
      provider: "codex",
      runtime_id: runtime.id,
      provider_account_id: account.id
    })

    plain = provider_account_fixture(ctx.alice, %{name: "plain"})
    assert {:ok, _} = Agents.update(ctx.alice_scope, "keel/dev", %{provider_account_id: plain.id})

    Map.merge(ctx, %{
      daemon: daemon,
      account: account,
      header_agent: agent_actor(ctx.workspace, "keel/headers")
    })
  end

  test "version 5 claims headers including replacements without exposing values in inspect",
       ctx do
    assert {:ok, agent} = Agents.get(ctx.alice_scope, "keel/headers")
    assert agent.provider_account.headers == ["Ocp-Apim-Subscription-Key", "user"]
    refute inspect(agent, limit: :infinity) =~ "header-one-sentinel"
    run = run_fixture(ctx.header_agent)
    assert {:ok, [spec]} = Runs.claim(%{daemon_ctx(ctx.daemon) | protocol: 5}, "http://localhost")
    assert spec.run_id == run.id

    assert Enum.map(spec.agent.provider_account.headers, &{&1.name, &1.value}) == [
             {"Ocp-Apim-Subscription-Key", "header-two-sentinel"},
             {"user", "header-one-sentinel"}
           ]

    refute inspect(spec) =~ "header-one-sentinel"

    assert {:ok, _} =
             ProviderAccounts.update(Scope.for_user(ctx.alice), ctx.account.id, %{
               headers: %{
                 "set" => %{"USER" => "new-header-sentinel"},
                 "delete" => ["Ocp-Apim-Subscription-Key"]
               }
             })

    second = run_fixture(ctx.header_agent)
    assert {:ok, [spec]} = Runs.claim(%{daemon_ctx(ctx.daemon) | protocol: 5}, "http://localhost")
    assert spec.run_id == second.id
    assert [%{name: "USER", value: "new-header-sentinel"}] = spec.agent.provider_account.headers
  end

  test "version 4 skips headers while a plain account claims and availability follows the required version",
       ctx do
    bound = run_fixture(ctx.header_agent)
    plain = run_fixture(ctx.agent)
    assert {:ok, availability} = Dispatch.availability(ctx.alice_scope)
    assert availability["keel/headers"].result == {:skipped, :daemon_outdated}
    assert availability["keel/dev"].result == :ok
    assert {:ok, [spec]} = Runs.claim(%{daemon_ctx(ctx.daemon) | protocol: 4}, "http://localhost")
    assert spec.run_id == plain.id
    assert Repo.get!(Run, bound.id).status == :queued
    assert {:ok, reply} = Reply.Claim.new(runs: [spec])
    assert {:ok, wire} = Messages.encode_reply("claim", reply, 4)
    refute Map.has_key?(hd(wire["runs"])["agent"]["provider_account"], "headers")
    Repo.update_all(from(d in Daemon, where: d.id == ^ctx.daemon.id), set: [protocol_version: 5])
    assert {:ok, availability} = Dispatch.availability(ctx.alice_scope)
    assert availability["keel/headers"].result == :ok
  end
end
