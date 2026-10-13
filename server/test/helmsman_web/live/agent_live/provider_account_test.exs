defmodule HelmsmanWeb.AgentLive.ProviderAccountTest do
  @moduledoc """
  Spec web-agents Agent 表单的供应商账号 and Agent 详情页的供应商账号; web-runs 守护进程版本过旧的提示
  on the agent page (add-provider-accounts-ui D7–D10).
  """
  use HelmsmanWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import HelmsmanWeb.PortalHelpers
  import HelmsmanWeb.LiveHelpers
  import Helmsman.AccountsFixtures
  import Helmsman.AgentsFixtures
  import Helmsman.ProviderAccountsFixtures
  import Helmsman.WorkspacesFixtures

  alias Helmsman.Accounts.Scope
  alias Helmsman.{Agents, ProviderAccounts, Repo}
  alias HelmsmanWeb.AgentForm

  setup %{conn: conn} do
    alice = user_fixture(%{display_name: "alice"})
    ws = workspace_fixture(alice, %{name: "Acme"})
    adam = user_fixture(%{display_name: "adam"})
    bob = user_fixture(%{display_name: "bob"})
    vic = user_fixture(%{display_name: "vic"})
    member_fixture(ws, adam, :admin)
    member_fixture(ws, bob, :member)
    member_fixture(ws, vic, :viewer)
    alice_scope = workspace_scope_fixture(alice, ws)

    {mbp, _} = daemon_fixture(alice, %{name: "mbp", workspace_ids: [ws.id]})
    claude = runtime_fixture(ws, mbp, %{provider: "claude", models: ["sonnet", "opus"]})
    codex = runtime_fixture(ws, mbp, %{provider: "codex"})
    copilot = runtime_fixture(ws, mbp, %{provider: "copilot"})

    zai =
      provider_account_fixture(alice, %{
        name: "zai",
        base_url: "https://api.z.ai/api/anthropic",
        api_key: "sk-zai-1",
        models: %{"default" => "glm-5.3", "haiku" => "glm-4.7-air"}
      })

    oa =
      provider_account_fixture(alice, %{
        name: "oa",
        cli: "codex",
        base_url: "https://oa.example.com/v1",
        models: %{"default" => "gpt-5"}
      })

    provider_account_fixture(bob, %{name: "volc", base_url: "https://ark.example.com/api"})
    provider_account_fixture(adam, %{name: "adam-acct", base_url: "https://adam.example.com"})

    managed_agent_fixture(alice_scope, %{
      name: "keel/claude-zai",
      runtime_id: claude.id,
      provider_account_id: zai.id
    })

    managed_agent_fixture(alice_scope, %{name: "keel/dev", runtime_id: claude.id})

    %{
      conn: conn,
      ws: ws,
      users: %{alice: alice, adam: adam, bob: bob, vic: vic},
      alice_scope: alice_scope,
      claude: claude,
      codex: codex,
      copilot: copilot,
      zai: zai,
      oa: oa,
      mbp: mbp,
      agents: "/w/#{ws.slug}/agents",
      zai_agent: "/w/#{ws.slug}/agents/keel/claude-zai"
    }
  end

  defp open(ctx, who, path), do: live(log_in_user(ctx.conn, ctx.users[who]), path)
  defp agent(ctx, name), do: elem(Agents.get(ctx.alice_scope, name), 1)
  defp in_panel?(view, selector, text \\ nil), do: in_portal?(view, "agent-panel", selector, text)
  defp attr(view, selector, name), do: portal_attr(view, "agent-panel", selector, name)

  defp option_texts(view, select),
    do:
      view
      |> portal("agent-panel")
      |> LazyHTML.query("#{select} option")
      |> Enum.map(&LazyHTML.text/1)

  defp selected(view, select), do: attr(view, "#{select} option[selected]", "value") || ""

  defp new_params(ctx, overrides) do
    Map.merge(
      %{
        "name" => "keel/new",
        "description" => "",
        "provider" => "claude",
        "runtime_id" => to_string(ctx.claude.id),
        "provider_account_id" => "",
        "model" => "",
        "effort" => "",
        "instructions" => "",
        "custom_args" => "",
        "access" => "owner_only",
        "access_member_ids" => [""],
        "capabilities" => [""],
        "max_concurrency" => "2",
        "timeout_minutes" => "120",
        "idle_timeout_minutes" => "20",
        "env_delete" => [""],
        "mcp" => ""
      },
      overrides
    )
  end

  defp change(view, params),
    do: render_change(view, "agent_form_change", %{"agent" => params})

  describe "Agent 表单的供应商账号" do
    test "只列出自己同 CLI 的账号", ctx do
      {:ok, view, _html} = open(ctx, :alice, ctx.agents <> "?panel=new-agent")

      assert option_texts(view, "#agent-provider-account") == ["CLI 默认登录", "zai · api.z.ai"]
      assert in_panel?(view, ~s(#agent-provider-account-manage[target="_blank"]), "管理供应商账号")

      change(view, new_params(ctx, %{"provider" => "codex"}))
      assert option_texts(view, "#agent-provider-account") == ["CLI 默认登录", "oa · oa.example.com"]
    end

    test "no account of the CLI links to the new panel", ctx do
      :ok = ProviderAccounts.delete(Scope.for_user(ctx.users.alice), ctx.oa.id)
      {:ok, view, _html} = open(ctx, :alice, ctx.agents <> "?panel=new-agent")
      change(view, new_params(ctx, %{"provider" => "codex"}))

      assert option_texts(view, "#agent-provider-account") == ["CLI 默认登录"]
      assert in_panel?(view, "#agent-provider-account-help", "还没有 Codex 的供应商账号")

      assert attr(view, "#agent-provider-account-add", "href") ==
               "/users/settings/provider-accounts?panel=new"

      assert attr(view, "#agent-provider-account-add", "target") == "_blank"
    end

    test "绑定账号新建 Agent", ctx do
      {:ok, view, _html} = open(ctx, :alice, ctx.agents <> "?panel=new-agent")

      params =
        new_params(ctx, %{
          "name" => "keel/zai-2",
          "provider_account_id" => to_string(ctx.zai.id),
          "model" => "glm-5.3"
        })

      change(view, params)
      render_submit(view, "agent_form_submit", %{"agent" => params})
      {path, _flash} = assert_redirect(view)
      assert path == ctx.agents <> "/keel/zai-2"

      {:ok, view, html} = open(ctx, :alice, path)
      assert has_element?(view, "#agent-properties [data-provider-account-row]", "zai")
      assert has_element?(view, "#agent-properties [data-provider-account-row]", "api.z.ai")
      assert has_element?(view, "#agent-properties [data-model]", "glm-5.3")
      refute html =~ "sk-zai-1"
    end

    test "选账号后模型改为自由输入; back to the CLI login clears an unknown model", ctx do
      {:ok, view, _html} = open(ctx, :alice, ctx.agents <> "?panel=new-agent")
      change(view, new_params(ctx, %{}))
      assert option_texts(view, "#agent-model") == ["CLI 缺省", "sonnet", "opus"]

      change(view, new_params(ctx, %{"provider_account_id" => to_string(ctx.zai.id)}))
      assert in_panel?(view, "input#agent-model")
      assert attr(view, "#agent-model", "placeholder") == "账号的缺省模型"
      assert in_panel?(view, "#agent-model-account-hint", "留空使用 glm-5.3")
      assert in_panel?(view, "#agent-model-account-hint", "haiku → glm-4.7-air")

      change(
        view,
        new_params(ctx, %{"provider_account_id" => to_string(ctx.zai.id), "model" => "glm-5.3"})
      )

      change(view, new_params(ctx, %{"provider_account_id" => "", "model" => "glm-5.3"}))
      assert in_panel?(view, "select#agent-model")
      assert selected(view, "#agent-model") == ""
      assert in_panel?(view, "#agent-model-cleared", "已清空：glm-5.3 不在运行时上报的模型里")
    end

    test "换 CLI 清空账号", ctx do
      {:ok, view, _html} = open(ctx, :alice, ctx.agents <> "?panel=new-agent")
      change(view, new_params(ctx, %{"provider_account_id" => to_string(ctx.zai.id)}))
      assert selected(view, "#agent-provider-account") == to_string(ctx.zai.id)

      change(
        view,
        new_params(ctx, %{"provider" => "codex", "provider_account_id" => to_string(ctx.zai.id)})
      )

      assert selected(view, "#agent-provider-account") == ""
    end

    test "其他 CLI: no field, nothing submitted", ctx do
      {:ok, view, _html} = open(ctx, :alice, ctx.agents <> "?panel=new-agent")
      change(view, new_params(ctx, %{"provider" => "copilot"}))
      refute in_panel?(view, "#agent-provider-account")
      refute in_panel?(view, "#agent-env-provider-hint")

      change(view, new_params(ctx, %{"provider" => "codex"}))
      assert in_panel?(view, "#agent-env-provider-hint", "OPENAI_*")
      change(view, new_params(ctx, %{"provider" => "claude"}))
      assert in_panel?(view, "#agent-env-provider-hint", "ANTHROPIC_*")
    end

    test "已绑定账号的 Agent 改用不支持账号的 CLI", ctx do
      {:ok, view, _html} = open(ctx, :alice, ctx.zai_agent <> "?panel=edit")
      assert selected(view, "#agent-provider-account") == to_string(ctx.zai.id)

      change(view, %{"provider" => "copilot"})
      refute in_panel?(view, "#agent-provider-account")

      render_submit(view, "agent_form_submit", %{
        "agent" => %{"provider" => "copilot", "runtime_id" => to_string(ctx.copilot.id)}
      })

      refute open?(view, "agent-panel")
      agent = agent(ctx, "keel/claude-zai")
      assert agent.provider == "copilot"
      assert agent.provider_account == nil
      refute has_element?(view, "#agent-properties [data-provider-account-row]")

      render_patch(view, ctx.zai_agent <> "?panel=edit")
      change(view, %{"provider" => "claude"})
      assert selected(view, "#agent-provider-account") == ""
    end

    test "改 CLI 失败时绑定不变", ctx do
      {:ok, view, _html} = open(ctx, :alice, ctx.zai_agent <> "?panel=edit")
      Repo.update!(Ecto.Changeset.change(ctx.copilot, disabled_at: DateTime.utc_now(:second)))

      change(view, %{"provider" => "copilot"})

      render_submit(view, "agent_form_submit", %{
        "agent" => %{"provider" => "copilot", "runtime_id" => to_string(ctx.copilot.id)}
      })

      assert open?(view, "agent-panel")
      assert in_panel?(view, "[role=alert]", "请修正下列错误")
      assert in_panel?(view, "#agent-form-execution .text-danger-fg")
      agent = agent(ctx, "keel/claude-zai")
      assert agent.provider == "claude"
      assert agent.provider_account.id == ctx.zai.id
    end

    test "admin 编辑别人的 Agent", ctx do
      {:ok, view, _html} = open(ctx, :adam, ctx.zai_agent <> "?panel=edit")

      assert option_texts(view, "#agent-provider-account") == ["CLI 默认登录", "zai · api.z.ai"]
      assert selected(view, "#agent-provider-account") == to_string(ctx.zai.id)
      refute in_panel?(view, "#agent-provider-account", "adam-acct")
      refute in_panel?(view, "#agent-provider-account-help")
      assert in_panel?(view, "#agent-form-execution[disabled]")

      render_submit(view, "agent_form_submit", %{"agent" => %{"max_concurrency" => "4"}})
      refute open?(view, "agent-panel")

      agent = agent(ctx, "keel/claude-zai")
      assert agent.max_concurrency == 4
      assert agent.provider_account.id == ctx.zai.id
    end

    test "另一个标签页新建账号", ctx do
      {:ok, view, _html} = open(ctx, :alice, ctx.agents <> "?panel=new-agent")
      change(view, new_params(ctx, %{"name" => "keel/half-done"}))

      provider_account_fixture(ctx.users.alice, %{
        name: "volc",
        base_url: "https://ark.cn-beijing.example.com/api"
      })

      eventually(fn ->
        "volc · ark.cn-beijing.example.com" in option_texts(view, "#agent-provider-account")
      end)

      assert open?(view, "agent-panel")
      assert attr(view, "#agent-name", "value") == "keel/half-done"
    end

    test "a selected account deleted meanwhile stays as the current item", ctx do
      volc = provider_account_fixture(ctx.users.alice, %{name: "volc"})
      {:ok, view, _html} = open(ctx, :alice, ctx.agents <> "?panel=new-agent")
      change(view, new_params(ctx, %{"provider_account_id" => to_string(volc.id)}))

      :ok = ProviderAccounts.delete(Scope.for_user(ctx.users.alice), volc.id)

      eventually(fn -> in_panel?(view, "#agent-provider-account-gone", "该账号已不存在") end)
      assert "volc（当前）" in option_texts(view, "#agent-provider-account")
      assert selected(view, "#agent-provider-account") == to_string(volc.id)
    end

    test "a binding changed elsewhere shows the modified notice", ctx do
      {:ok, view, _html} = open(ctx, :alice, ctx.zai_agent <> "?panel=edit")
      {:ok, _} = Agents.update(ctx.alice_scope, "keel/claude-zai", %{provider_account_id: nil})

      eventually(fn -> in_panel?(view, "#agent-form-notice", "已被修改") end)
    end
  end

  describe "AgentForm.attrs/2 and the binding" do
    defp edit_form(ctx, name) do
      view = agent(ctx, name)
      AgentForm.edit(ctx.alice_scope, 1, view, %{configure: true, administer: true})
    end

    defp with_params(form, params), do: %{form | params: Map.merge(form.params, params)}

    test "a bound agent moved to copilot / cursor submits provider_account_id: nil", ctx do
      for provider <- ~w(copilot cursor) do
        form = ctx |> edit_form("keel/claude-zai") |> with_params(%{"provider" => provider})
        assert {:ok, attrs} = AgentForm.attrs(form, %{})
        assert Map.fetch(attrs, :provider_account_id) == {:ok, nil}
      end
    end

    test "nothing about the binding when it does not change", ctx do
      form = edit_form(ctx, "keel/claude-zai")
      assert {:ok, attrs} = AgentForm.attrs(form, %{})
      refute Map.has_key?(attrs, :provider_account_id)

      form = ctx |> edit_form("keel/dev") |> with_params(%{"provider" => "copilot"})
      assert {:ok, attrs} = AgentForm.attrs(form, %{})
      refute Map.has_key?(attrs, :provider_account_id)
    end

    test "a new copilot agent has no provider_account_id; a claude one with an account has",
         ctx do
      form = AgentForm.new(ctx.alice_scope, 1) |> with_params(%{"provider" => "copilot"})
      assert {:ok, attrs} = AgentForm.attrs(form, %{})
      refute Map.has_key?(attrs, :provider_account_id)

      form = AgentForm.new(ctx.alice_scope, 1)
      assert {:ok, attrs} = AgentForm.attrs(form, %{})
      refute Map.has_key?(attrs, :provider_account_id)

      form = with_params(form, %{"provider_account_id" => to_string(ctx.zai.id)})
      assert {:ok, %{provider_account_id: id}} = AgentForm.attrs(form, %{})
      assert id == ctx.zai.id
    end

    test "without configure? nothing of the execution group", ctx do
      view = agent(ctx, "keel/claude-zai")

      form =
        ctx.alice_scope
        |> AgentForm.edit(1, view, %{configure: false, administer: true})
        |> with_params(%{"provider" => "copilot"})

      assert {:ok, attrs} = AgentForm.attrs(form, %{})
      refute Map.has_key?(attrs, :provider_account_id)
      refute Map.has_key?(attrs, :provider)
    end
  end

  describe "Agent 详情页的供应商账号" do
    test "工作区成员查看", ctx do
      {:ok, view, html} = open(ctx, :vic, ctx.zai_agent)
      row = "#agent-properties [data-provider-account-row]"

      assert has_element?(view, "#{row} [data-account-name]", "zai")
      assert has_element?(view, "#{row} [data-account-host]", "api.z.ai")
      refute has_element?(view, "#{row} a")
      assert has_element?(view, "#agent-properties [data-model]", "账号缺省")

      for html <- [html, render(view)] do
        refute html =~ "/api/anthropic"
        refute html =~ "sk-zai-1"
        refute html =~ "glm-4.7-air"
      end
    end

    test "所属用户查看", ctx do
      {:ok, view, _html} = open(ctx, :alice, ctx.zai_agent)

      assert has_element?(
               view,
               ~s(#agent-properties [data-provider-account-row] a[href="/users/settings/provider-accounts?panel=edit&id=#{ctx.zai.id}"]),
               "zai"
             )
    end

    test "未绑定; copilot has no row", ctx do
      {:ok, view, _html} = open(ctx, :bob, ctx.agents <> "/keel/dev")
      assert has_element?(view, "#agent-properties [data-provider-account-row]", "CLI 默认登录")
      assert has_element?(view, "#agent-properties [data-model]", "CLI 缺省")

      managed_agent_fixture(ctx.alice_scope, %{
        name: "keel/pilot",
        provider: "copilot",
        runtime_id: ctx.copilot.id
      })

      {:ok, view, _html} = open(ctx, :bob, ctx.agents <> "/keel/pilot")
      refute has_element?(view, "#agent-properties [data-provider-account-row]")
    end

    test "改名后自动更新", ctx do
      {:ok, view, _html} = open(ctx, :bob, ctx.zai_agent)

      {:ok, _} =
        ProviderAccounts.update(Scope.for_user(ctx.users.alice), ctx.zai.id, %{name: "zai-main"})

      eventually(fn ->
        has_element?(view, "#agent-properties [data-account-name]", "zai-main")
      end)
    end
  end

  describe "守护进程版本过旧的提示" do
    test "运行按钮的说明", ctx do
      old = HelmsmanProtocol.provider_account_version() - 1
      Repo.update!(Ecto.Changeset.change(ctx.mbp, protocol_version: old))

      {:ok, view, _html} = open(ctx, :alice, ctx.zai_agent)
      assert has_element?(view, "#agent-run[aria-disabled]")
      assert has_element?(view, "#agent-run-reason", "keel/claude-zai 所在机器的守护进程版本过旧")

      {:ok, view, _html} = open(ctx, :alice, ctx.agents <> "/keel/dev")
      refute has_element?(view, "#agent-run[aria-disabled]")
    end
  end
end
