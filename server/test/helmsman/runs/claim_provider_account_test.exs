defmodule Helmsman.Runs.ClaimProviderAccountTest do
  # add-provider-accounts 3.4: claiming the runs of an agent bound to a
  # provider account (provider-accounts「运行使用 Agent 绑定的供应商账号」,
  # decisions 4, 12).
  use Helmsman.DataCase, async: true

  import Helmsman.AgentsFixtures
  import Helmsman.ProviderAccountsFixtures
  import Helmsman.RunsFixtures

  alias Helmsman.Accounts.Scope
  alias Helmsman.Agents
  alias Helmsman.Daemons.Daemon
  alias Helmsman.ProviderAccounts
  alias Helmsman.Runs
  alias Helmsman.Runs.Run

  @vp HelmsmanProtocol.provider_account_version()

  setup do
    ctx = dispatch_fixture()
    daemon = daemon_of(ctx.agent)
    Repo.update_all(from(d in Daemon, where: d.id == ^daemon.id), set: [max_concurrency: 8])

    zai =
      provider_account_fixture(ctx.alice, %{
        name: "zai",
        api_key: "sk-zai-1",
        models: %{"default" => "glm-5.3", "haiku" => "glm-4.5-air"}
      })

    managed_agent_fixture(ctx.alice_scope, %{
      name: "keel/claude-zai",
      runtime_id: profile(ctx.agent).runtime_id,
      provider_account_id: zai.id
    })

    Map.merge(ctx, %{
      daemon: daemon,
      zai: zai,
      zai_agent: agent_actor(ctx.workspace, "keel/claude-zai"),
      user_scope: Scope.for_user(ctx.alice)
    })
  end

  defp claim(ctx, protocol \\ @vp),
    do: Runs.claim(%{daemon_ctx(ctx.daemon) | protocol: protocol}, "http://localhost")

  defp reload(run), do: Repo.get!(Run, run.id)

  test "the description carries the account; the run records it (scenario)", ctx do
    run = run_fixture(ctx.zai_agent)

    assert {:ok, [spec]} = claim(ctx)
    assert spec.run_id == run.id

    assert %HelmsmanProtocol.ProviderAccount{
             base_url: "https://api.z.ai/api/anthropic",
             api_key: "sk-zai-1",
             models: %{"default" => "glm-5.3", "haiku" => "glm-4.5-air"}
           } = spec.agent.provider_account

    refute inspect(spec) =~ "sk-zai-1"
    assert reload(run).provider_account_id == ctx.zai.id
    assert {:ok, %{provider_account_name: "zai"}} = Runs.get(ctx.alice_scope, run.id)
  end

  test "an unbound agent's run has no account", ctx do
    run = run_fixture(ctx.agent)
    assert {:ok, [%{agent: %{provider_account: nil}}]} = claim(ctx)
    assert reload(run).provider_account_id == nil
    assert {:ok, %{provider_account_name: nil}} = Runs.get(ctx.alice_scope, run.id)
  end

  test "an older daemon leaves the bound runs queued (scenario)", ctx do
    bound = run_fixture(ctx.zai_agent)
    plain = run_fixture(ctx.agent)

    assert {:ok, [spec]} = claim(ctx, @vp - 1)
    assert spec.run_id == plain.id
    assert reload(bound).status == :queued

    assert {:ok, [spec]} = claim(ctx)
    assert spec.run_id == bound.id
  end

  test "without a negotiated version the bound runs stay queued", ctx do
    bound = run_fixture(ctx.zai_agent)
    ctx_without = Map.delete(daemon_ctx(ctx.daemon), :protocol)
    assert {:ok, []} = Runs.claim(ctx_without, "http://localhost")
    assert reload(bound).status == :queued
  end

  test "a new key only reaches runs claimed later (scenario)", ctx do
    first = run_fixture(ctx.zai_agent)
    assert {:ok, [old]} = claim(ctx)

    assert {:ok, _} = ProviderAccounts.update(ctx.user_scope, ctx.zai.id, %{api_key: "sk-zai-2"})
    second = run_fixture(ctx.zai_agent)
    assert {:ok, [new]} = claim(ctx)

    assert {old.run_id, new.run_id} == {first.id, second.id}
    assert old.agent.provider_account.api_key == "sk-zai-1"
    assert new.agent.provider_account.api_key == "sk-zai-2"
  end

  test "after the account is deleted the run shows no account", ctx do
    run = run_fixture(ctx.zai_agent)
    assert {:ok, [_]} = claim(ctx)

    {:ok, _} = Agents.update(ctx.alice_scope, "keel/claude-zai", %{provider_account_id: nil})
    assert ProviderAccounts.delete(ctx.user_scope, ctx.zai.id) == :ok

    assert reload(run).provider_account_id == nil
    assert {:ok, %{provider_account_name: nil}} = Runs.get(ctx.alice_scope, run.id)
    assert [%{provider_account_name: nil}] = Runs.summaries([reload(run)])
  end
end
