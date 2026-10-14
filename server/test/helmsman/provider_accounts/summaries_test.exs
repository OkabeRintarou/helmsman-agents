defmodule Helmsman.ProviderAccounts.SummariesTest do
  # add-actor-avatars domain-request-2 R9 / R10: the account summary of
  # agent and run views (icon, host and the port written in the address).
  use Helmsman.DataCase, async: true

  import Helmsman.ProviderAccountsFixtures
  import Helmsman.RunsFixtures

  alias Helmsman.Accounts.Scope
  alias Helmsman.{Agents, ProviderAccounts, Runs}

  setup do
    ctx = dispatch_fixture()
    scope = Scope.for_user(ctx.alice)

    zai =
      provider_account_fixture(ctx.alice, %{
        name: "zai",
        api_key: "sk-zai-secret",
        headers: %{"X-Org" => "org-secret"},
        cli: "codex",
        models: %{"default" => "glm-5.3"}
      })

    {:ok, zai} = ProviderAccounts.update(scope, zai.id, %{icon: "zai"})
    Map.merge(ctx, %{scope: scope, zai: zai})
  end

  test "summaries: host, the written port only, header names, icon; no secrets", ctx do
    ollama =
      provider_account_fixture(ctx.alice, %{name: "ollama", base_url: "http://localhost:11434"})

    explicit =
      provider_account_fixture(ctx.alice, %{
        name: "explicit",
        base_url: "https://h.example:443/v1"
      })

    v6 = provider_account_fixture(ctx.alice, %{name: "v6", base_url: "http://[::1]/x"})
    v6_port = provider_account_fixture(ctx.alice, %{name: "v6p", base_url: "http://[::1]:8080"})

    summaries =
      ProviderAccounts.summaries([ctx.zai.id, ollama.id, explicit.id, v6.id, v6_port.id])

    assert summaries[ctx.zai.id] == %{
             id: ctx.zai.id,
             name: "zai",
             cli: "codex",
             host: "api.z.ai",
             port: nil,
             headers: ["X-Org"],
             icon: "zai"
           }

    assert %{host: "localhost", port: 11_434, icon: nil} = summaries[ollama.id]
    assert %{host: "h.example", port: 443} = summaries[explicit.id]
    assert %{host: "::1", port: nil} = summaries[v6.id]
    assert %{host: "::1", port: 8080} = summaries[v6_port.id]

    text = inspect(summaries, limit: :infinity)
    refute text =~ "sk-zai-secret"
    refute text =~ "org-secret"
    refute text =~ "/api/anthropic"
    assert ProviderAccounts.summaries([]) == %{}
  end

  test "the agent view and the run view carry the same summary", ctx do
    claude = provider_account_fixture(ctx.alice, %{name: "zai-claude"})
    {:ok, claude} = ProviderAccounts.update(ctx.scope, claude.id, %{icon: "zai"})
    {:ok, _} = Agents.update(ctx.alice_scope, "keel/dev", %{provider_account_id: claude.id})
    {:ok, %{provider_account: summary}} = Agents.get(ctx.alice_scope, "keel/dev")
    assert %{icon: "zai", host: "api.z.ai", port: nil} = summary

    run = run_fixture(ctx.agent, %{provider_account_id: claude.id})
    {_viewer, viewer_scope} = member_scope_fixture(ctx.workspace, :viewer)

    assert {:ok, %{provider_account: ^summary, provider_account_name: "zai-claude"}} =
             Runs.get(viewer_scope, run.id)

    plain = run_fixture(ctx.agent)

    assert [%{provider_account: ^summary}, %{provider_account: nil, provider_account_name: nil}] =
             Runs.summaries([run, plain])
  end
end
