defmodule Helmsman.Agents.ProviderAccountBindingTest do
  # add-provider-accounts 3.3: binding a managed agent to a provider account
  # (managed-agents「绑定供应商账号」, decision 14).
  use Helmsman.DataCase, async: true

  import Helmsman.AccountsFixtures
  import Helmsman.AgentsFixtures
  import Helmsman.ProviderAccountsFixtures
  import Helmsman.RunsFixtures

  alias Helmsman.Accounts.Scope
  alias Helmsman.Agents
  alias Helmsman.Daemons.Runtime
  alias Helmsman.Events
  alias Helmsman.ProviderAccounts
  alias Helmsman.Runs

  setup do
    ctx = dispatch_fixture()
    zai = provider_account_fixture(ctx.alice, %{name: "zai", api_key: "sk-zai-1"})
    Map.put(ctx, :zai, zai)
  end

  defp bind(ctx, scope \\ nil, name \\ "keel/dev", id),
    do: Agents.update(scope || ctx.alice_scope, name, %{provider_account_id: id})

  defp error(result) do
    assert {:error, %Ecto.Changeset{} = cs} = result
    errors_on(cs)
  end

  defp bound(ctx, name \\ "keel/dev"),
    do: profile(agent_actor(ctx.workspace, name)).provider_account_id

  describe "binding" do
    test "the user's own account (scenario)", ctx do
      assert {:ok, %{provider_account: summary}} = bind(ctx, ctx.zai.id)

      assert summary == %{
               id: ctx.zai.id,
               name: "zai",
               cli: "claude",
               host: "api.z.ai",
               headers: []
             }

      {_viewer, viewer_scope} = member_scope_fixture(ctx.workspace, :viewer)
      assert {:ok, view} = Agents.get(viewer_scope, "keel/dev")
      assert view.provider_account == summary
      text = inspect(view, limit: :infinity)
      refute text =~ "sk-zai-1"
      refute text =~ "/api/anthropic"

      assert {:ok, [listed]} = Agents.list(viewer_scope)
      assert listed.provider_account == summary
    end

    test "another user's account: the same error as no account (scenario)", ctx do
      bob = provider_account_fixture(user_fixture(), %{name: "bob"})
      assert %{provider_account_id: [message]} = error(bind(ctx, bob.id))
      assert %{provider_account_id: [^message]} = error(bind(ctx, bob.id + 1_000_000))
      assert message == "does not exist"
      assert bound(ctx) == nil
    end

    test "a different CLI (scenario)", ctx do
      {daemon, _} = daemon_fixture(ctx.alice, %{workspace_ids: [ctx.workspace.id]})
      runtime = runtime_fixture(ctx.workspace, daemon, %{provider: "codex"})

      managed_agent_fixture(ctx.alice_scope, %{
        name: "keel/codex",
        provider: "codex",
        runtime_id: runtime.id
      })

      assert %{provider_account_id: ["is for claude"]} =
               error(bind(ctx, nil, "keel/codex", ctx.zai.id))

      assert {:ok, _} =
               Agents.create(ctx.alice_scope, %{
                 name: "keel/codex2",
                 provider: "codex",
                 runtime_id: runtime.id
               })

      assert %{provider_account_id: ["is for claude"]} =
               error(
                 Agents.create(ctx.alice_scope, %{
                   name: "keel/codex3",
                   provider: "codex",
                   runtime_id: runtime.id,
                   provider_account_id: ctx.zai.id
                 })
               )
    end

    test "changing the agent's CLI away from its account's", ctx do
      {:ok, _} = bind(ctx, ctx.zai.id)

      assert %{provider_account_id: ["is for claude"]} =
               error(Agents.update(ctx.alice_scope, "keel/dev", %{provider: "codex"}))
    end

    test "a shared account: a new key reaches every agent's next runs (scenario)", ctx do
      runtime_id = profile(ctx.agent).runtime_id

      managed_agent_fixture(ctx.alice_scope, %{
        name: "keel/reviewer",
        runtime_id: runtime_id,
        provider_account_id: ctx.zai.id
      })

      {:ok, _} = bind(ctx, ctx.zai.id)

      assert {:ok, _} =
               ProviderAccounts.update(Scope.for_user(ctx.alice), ctx.zai.id, %{
                 api_key: "sk-zai-2"
               })

      for name <- ["keel/dev", "keel/reviewer"],
          do: run_fixture(agent_actor(ctx.workspace, name))

      daemon = daemon_of(ctx.agent)

      Repo.update_all(from(d in Helmsman.Daemons.Daemon, where: d.id == ^daemon.id),
        set: [max_concurrency: 4]
      )

      assert {:ok, specs} = Runs.claim(daemon_ctx(daemon), "http://localhost")

      assert specs |> Enum.map(& &1.agent.name) |> Enum.sort() == ["keel/dev", "keel/reviewer"]
      assert Enum.all?(specs, &(&1.agent.provider_account.api_key == "sk-zai-2"))
    end
  end

  describe "models (scenarios of 运行时只能绑定所属用户自己的 Agent)" do
    setup ctx do
      Repo.update_all(from(r in Runtime, where: r.id == ^profile(ctx.agent).runtime_id),
        set: [models: ["sonnet", "opus"], efforts: ["high"]]
      )

      :ok
    end

    test "a model the runtime did not report: refused without an account", ctx do
      assert %{model: _} = error(Agents.update(ctx.alice_scope, "keel/dev", %{model: "gpt-x"}))
    end

    test "with a provider account any model name is accepted; effort still checked", ctx do
      assert {:ok, %{model: "glm-5.3"}} =
               Agents.update(ctx.alice_scope, "keel/dev", %{
                 provider_account_id: ctx.zai.id,
                 model: "glm-5.3"
               })

      assert %{effort: _} = error(Agents.update(ctx.alice_scope, "keel/dev", %{effort: "max"}))

      assert %{model: _} =
               error(
                 Agents.update(ctx.alice_scope, "keel/dev", %{model: String.duplicate("m", 129)})
               )
    end
  end

  describe "who may change the binding" do
    test "an admin may not clear another user's account (scenario)", ctx do
      {:ok, _} = bind(ctx, ctx.zai.id)
      {_admin, admin_scope} = member_scope_fixture(ctx.workspace, :admin)

      assert bind(ctx, admin_scope, "keel/dev", nil) == {:error, :forbidden}

      assert Agents.update(admin_scope, "keel/dev", %{
               description: "x",
               provider_account_id: nil
             }) == {:error, :forbidden}

      assert bound(ctx) == ctx.zai.id
      assert profile(ctx.agent).description == ""
      assert {:ok, _} = Agents.update(admin_scope, "keel/dev", %{max_concurrency: 4})
      assert bound(ctx) == ctx.zai.id
    end

    test "an admin's own agent cannot use the agent owner's account", ctx do
      {admin, admin_scope} = member_scope_fixture(ctx.workspace, :admin)
      managed_agent_fixture(admin_scope, %{name: "keel/admins"})

      assert %{provider_account_id: ["does not exist"]} =
               error(bind(ctx, admin_scope, "keel/admins", ctx.zai.id))

      assert admin.id != ctx.alice.id
    end
  end

  describe "notifications to the owner's accounts topic" do
    setup ctx do
      Events.subscribe(ProviderAccounts.topic(ctx.alice.id))
      :ok
    end

    test "binding, rebinding, unbinding and archiving", ctx do
      other = provider_account_fixture(ctx.alice, %{name: "other"})
      assert_receive {:provider_accounts_changed}

      for id <- [ctx.zai.id, other.id, nil] do
        {:ok, _} = bind(ctx, id)
        assert_receive {:provider_accounts_changed}
      end

      {:ok, _} = bind(ctx, ctx.zai.id)
      assert_receive {:provider_accounts_changed}
      {:ok, _} = Agents.archive(ctx.alice_scope, "keel/dev")
      assert_receive {:provider_accounts_changed}
    end

    test "creating a bound agent; nothing for unrelated or failed changes", ctx do
      managed_agent_fixture(ctx.alice_scope, %{name: "keel/new", provider_account_id: ctx.zai.id})
      assert_receive {:provider_accounts_changed}

      {:ok, _} = Agents.update(ctx.alice_scope, "keel/dev", %{description: "x"})
      _ = bind(ctx, -1)
      {:ok, _} = Agents.archive(ctx.alice_scope, "keel/dev")
      refute_receive {:provider_accounts_changed}, 100
    end
  end
end
