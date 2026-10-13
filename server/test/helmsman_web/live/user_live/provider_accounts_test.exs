defmodule HelmsmanWeb.UserLive.ProviderAccountsTest do
  @moduledoc """
  Spec web-provider-accounts (add-provider-accounts-ui D1, D2, D4–D7): the personal
  settings layout, the accounts list, the new / edit panel, the write-only key,
  deletion and live refresh.
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
  alias Helmsman.{Agents, ProviderAccounts}
  alias Helmsman.ProviderAccounts.ProviderAccount

  @path "/users/settings/provider-accounts"

  setup %{conn: conn} do
    alice = user_fixture(%{display_name: "alice"})
    bob = user_fixture(%{display_name: "bob"})
    ws = workspace_fixture(alice)
    alice_ws = workspace_scope_fixture(alice, ws)

    %{
      conn: log_in_user(conn, alice),
      alice: alice,
      bob: bob,
      ws: ws,
      alice_ws: alice_ws,
      alice_scope: Scope.for_user(alice)
    }
  end

  defp sentinel, do: "sk-test-#{System.unique_integer([:positive])}"

  defp zai(ctx, attrs \\ %{}) do
    provider_account_fixture(
      ctx.alice,
      Map.merge(
        %{
          name: "zai",
          base_url: "https://api.z.ai/api/anthropic",
          api_key: "sk-zai-1",
          models: %{"default" => "glm-5.3", "haiku" => "glm-4.7-air"}
        },
        attrs
      )
    )
  end

  defp bind(ctx, name, account),
    do: managed_agent_fixture(ctx.alice_ws, %{name: name, provider_account_id: account.id})

  defp row(account), do: "#provider-account-#{account.id}"

  defp in_panel?(view, selector, text \\ nil),
    do: in_portal?(view, "provider-account-panel", selector, text)

  defp panel_html(view),
    do: view |> portal("provider-account-panel") |> LazyHTML.to_html()

  defp submit(view, params, raw_extra \\ %{}),
    do:
      render_submit(
        view,
        "account_form_submit",
        %{"account" => Map.merge(params, raw_extra)}
      )

  # The confirm button of the dialog: its on_cancel ("dismiss") then "delete" with the
  # account (`confirm_value`).
  defp confirm_delete(view, account) do
    render_click(view, "dismiss", %{})
    render_click(view, "delete", %{"id" => to_string(account.id), "name" => account.name})
  end

  defp state(view), do: view.pid |> :sys.get_state() |> inspect(limit: :infinity)

  defp stored_key(account),
    do: Helmsman.Repo.get!(ProviderAccount, account.id).api_key

  describe "个人设置布局与入口" do
    test "标签页切换", ctx do
      {:ok, view, _html} = live(ctx.conn, "/users/settings")
      assert has_element?(view, ~s(nav a[aria-current="page"][href="/users/settings"]), "账号")

      {:ok, view, _html} =
        view
        |> element(~s(nav a[href="#{@path}"]), "供应商账号")
        |> render_click()
        |> follow_redirect(ctx.conn, @path)

      assert has_element?(view, ~s(nav a[aria-current="page"][href="#{@path}"]), "供应商账号")
      refute has_element?(view, ~s(nav a[aria-current="page"][href="/users/settings"]))
      assert page_title(view) == "供应商账号 · Helmsman"
      refute has_element?(view, "#hm-sidebar")
      assert has_element?(view, ~s(#hm-back-to-workspace[href="/"]), "返回工作区")
      assert has_element?(view, "#hm-personal-user", "alice")
    end

    test "未登录访问: login, then back here" do
      conn = build_conn()
      assert {:error, {:redirect, %{to: "/users/log-in"}}} = live(conn, @path)

      conn = get(conn, @path)
      assert redirected_to(conn) == "/users/log-in"
      assert get_session(conn, :user_return_to) == @path
    end
  end

  describe "供应商账号列表" do
    test "列表只含自己的账号", ctx do
      zai = zai(ctx)
      provider_account_fixture(ctx.bob, %{name: "volc", api_key: "sk-volc-9"})

      {:ok, view, html} = live(ctx.conn, @path)

      assert [_] =
               view
               |> render()
               |> LazyHTML.from_fragment()
               |> LazyHTML.query("#provider-accounts > tr")
               |> Enum.to_list()

      assert has_element?(view, "#{row(zai)} [data-name]", "zai")
      assert has_element?(view, "#{row(zai)} [data-cli]", "Claude Code")
      assert has_element?(view, "#{row(zai)} [data-host]", "api.z.ai")

      assert has_element?(
               view,
               ~s(#{row(zai)} [data-address][title="https://api.z.ai/api/anthropic"])
             )

      assert has_element?(view, "#{row(zai)} [data-default-model]", "glm-5.3")
      assert has_element?(view, "#{row(zai)} [data-default-model]", "+1")
      assert has_element?(view, "#{row(zai)} [data-api-key]", "已设置")
      assert has_element?(view, "#provider-accounts-count", "1 / 32")
      assert has_element?(view, ~s(a#provider-accounts-new[href="#{@path}?panel=new"]))
      refute has_element?(view, "#provider-accounts-new[aria-disabled]")

      for html <- [html, render(view)] do
        refute html =~ "volc"
        refute html =~ "sk-zai-1"
        refute html =~ "sk-volc-9"
      end
    end

    test "rows are sorted by name, case-insensitively", ctx do
      for name <- ~w(beta Alpha gamma), do: provider_account_fixture(ctx.alice, %{name: name})
      {:ok, view, _html} = live(ctx.conn, @path)

      names =
        view
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("#provider-accounts [data-name]")
        |> Enum.map(&LazyHTML.text/1)

      assert names == ~w(Alpha beta gamma)
    end

    test "使用中的 Agent: unarchived only", ctx do
      zai = zai(ctx)
      bind(ctx, "claude-zai", zai)
      bind(ctx, "reviewer-zai", zai)
      bind(ctx, "old-zai", zai)
      {:ok, _} = Agents.archive(ctx.alice_ws, "old-zai")

      {:ok, view, _html} = live(ctx.conn, @path)
      slug = ctx.ws.slug

      assert has_element?(view, "#{row(zai)} [data-agent]", "#{slug}/claude-zai")
      assert has_element?(view, "#{row(zai)} [data-agent]", "#{slug}/reviewer-zai")
      refute has_element?(view, "#{row(zai)} [data-agents]", "old-zai")
    end

    test "an unused account says 未使用", ctx do
      zai = zai(ctx)
      {:ok, view, _html} = live(ctx.conn, @path)
      assert has_element?(view, "#{row(zai)} [data-agents]", "未使用")
    end

    test "达到上限", ctx do
      for i <- 1..32, do: provider_account_fixture(ctx.alice, %{name: "a#{i}"})

      {:ok, view, _html} = live(ctx.conn, @path)
      assert has_element?(view, "#provider-accounts-count", "32 / 32")
      assert has_element?(view, "#provider-accounts-new[aria-disabled]")
      assert has_element?(view, "#provider-accounts-new-reason", "最多 32 个供应商账号")

      {:ok, view, html} = live(ctx.conn, @path <> "?panel=new")
      refute open?(view, "provider-account-panel")
      assert html =~ "最多 32 个供应商账号"

      render_patch(view, @path <> "?panel=new")
      assert_patch(view, @path)
      refute open?(view, "provider-account-panel")
    end

    test "空状态", ctx do
      {:ok, view, _html} = live(ctx.conn, @path)
      assert has_element?(view, "#provider-accounts-empty", "还没有供应商账号")
      assert has_element?(view, "#provider-accounts-count", "0 / 32")

      view |> element("#provider-accounts-empty-new") |> render_click()
      assert_patch(view, @path <> "?panel=new")
      assert open?(view, "provider-account-panel")
      assert in_panel?(view, "#provider-account-panel-title", "新建供应商账号")
    end
  end

  describe "新建与编辑供应商账号" do
    test "新建 Claude 账号", ctx do
      {:ok, view, _html} = live(ctx.conn, @path <> "?panel=new")
      assert open?(view, "provider-account-panel")
      key = sentinel()

      html =
        submit(
          view,
          %{
            "name" => "zai",
            "cli" => "claude",
            "base_url" => "https://api.z.ai/api/anthropic",
            "models" => %{"default" => "glm-5.3", "opus" => ""}
          },
          %{"api_key" => key}
        )

      refute open?(view, "provider-account-panel")
      assert_patch(view, @path)
      assert html =~ "已创建 zai"

      {:ok, [zai]} = ProviderAccounts.list(ctx.alice_scope)
      assert zai.models == %{"default" => "glm-5.3"}
      assert stored_key(zai) == key
      assert has_element?(view, "#{row(zai)} [data-api-key]", "已设置")
      assert has_element?(view, "#{row(zai)} [data-default-model]", "glm-5.3")
      refute render(view) =~ key
      refute state(view) =~ key
    end

    test "地址错误保留输入", ctx do
      {:ok, view, _html} = live(ctx.conn, @path <> "?panel=new")

      submit(
        view,
        %{
          "name" => "zai",
          "cli" => "claude",
          "base_url" => "http://api.example.com/anthropic",
          "models" => %{"default" => "glm-5.3"}
        },
        %{"api_key" => sentinel()}
      )

      assert open?(view, "provider-account-panel")
      assert in_panel?(view, "#provider-account-form", "只有本机地址可以使用 http")

      assert portal_attr(view, "provider-account-panel", "#provider-account-name", "value") ==
               "zai"

      assert portal_attr(
               view,
               "provider-account-panel",
               "#provider-account-model-default",
               "value"
             ) ==
               "glm-5.3"

      assert {:ok, []} = ProviderAccounts.list(ctx.alice_scope)
    end

    test "Codex 缺缺省模型", ctx do
      {:ok, view, _html} = live(ctx.conn, @path <> "?panel=new")
      render_change(view, "account_form_change", %{"account" => %{"cli" => "codex"}})
      assert in_panel?(view, "#provider-account-model-default")
      refute in_panel?(view, "#provider-account-model-opus")
      assert in_panel?(view, "label[for=provider-account-model-default]", "必填")

      submit(
        view,
        %{
          "name" => "oa",
          "cli" => "codex",
          "base_url" => "https://api.example.com/v1",
          "models" => %{"default" => ""}
        },
        %{"api_key" => sentinel()}
      )

      assert open?(view, "provider-account-panel")
      assert in_panel?(view, "#provider-account-models-error", "缺省模型")
    end

    test "编辑时 CLI 只读; submitting a CLI is ignored", ctx do
      zai = zai(ctx)
      {:ok, view, _html} = live(ctx.conn, "#{@path}?panel=edit&id=#{zai.id}")

      assert open?(view, "provider-account-panel")
      assert in_panel?(view, "#provider-account-panel-title", "编辑 zai")
      assert in_panel?(view, "#provider-account-cli-readonly", "Claude Code")
      assert in_panel?(view, "#provider-account-cli-readonly", "创建后不能修改")
      refute in_panel?(view, "#provider-account-cli")

      submit(view, %{
        "name" => "zai",
        "cli" => "codex",
        "base_url" => zai.base_url,
        "models" => %{"default" => "glm-5.3"}
      })

      assert {:ok, %{cli: "claude"}} = ProviderAccounts.get(ctx.alice_scope, zai.id)
    end

    test "别人的账号 and an unknown id look the same", ctx do
      volc = provider_account_fixture(ctx.bob, %{name: "volc"})

      for id <- [volc.id, volc.id + 100_000, "abc"] do
        {:ok, view, html} = live(ctx.conn, "#{@path}?panel=edit&id=#{id}")
        refute open?(view, "provider-account-panel")
        assert html =~ "供应商账号不存在"
        refute html =~ "volc"

        render_patch(view, "#{@path}?panel=edit&id=#{id}")
        assert_patch(view, @path)
        refute open?(view, "provider-account-panel")
        refute render(view) =~ "volc"
      end
    end

    test "编辑面板列出使用者", ctx do
      zai = zai(ctx)
      bind(ctx, "claude-zai", zai)
      {:ok, view, _html} = live(ctx.conn, "#{@path}?panel=edit&id=#{zai.id}")

      slug = ctx.ws.slug

      assert in_panel?(
               view,
               ~s(#provider-account-agents a[href="/w/#{slug}/agents/claude-zai"]),
               "#{slug}/claude-zai"
             )

      assert in_panel?(view, "#provider-account-agents", "修改地址、密钥或模型映射只影响之后开始的运行")
    end

    test "a row click and the row menu open the edit panel", ctx do
      zai = zai(ctx)
      {:ok, view, _html} = live(ctx.conn, @path)

      view |> element(row(zai)) |> render_click()
      assert_patch(view, "#{@path}?panel=edit&id=#{zai.id}")
      assert open?(view, "provider-account-panel")

      assert has_element?(
               view,
               ~s(#provider-account-#{zai.id}-edit[href="#{@path}?panel=edit&id=#{zai.id}"]),
               "编辑"
             )
    end

    test "编辑成功 closes the panel with 已保存", ctx do
      zai = zai(ctx)
      {:ok, view, _html} = live(ctx.conn, "#{@path}?panel=edit&id=#{zai.id}")

      html =
        submit(view, %{
          "name" => "zai-main",
          "base_url" => zai.base_url,
          "models" => %{"default" => "glm-5.3"}
        })

      assert html =~ "已保存"
      refute open?(view, "provider-account-panel")
      assert has_element?(view, "#{row(zai)} [data-name]", "zai-main")
    end
  end

  describe "密钥只写" do
    test "编辑不回填", ctx do
      zai = zai(ctx)
      {:ok, view, html} = live(ctx.conn, "#{@path}?panel=edit&id=#{zai.id}")

      assert portal_attr(view, "provider-account-panel", "#provider-account-api-key", "value") ==
               ""

      assert portal_attr(view, "provider-account-panel", "#provider-account-api-key", "type") ==
               "password"

      assert portal_attr(
               view,
               "provider-account-panel",
               "#provider-account-api-key",
               "placeholder"
             ) ==
               "留空则不修改"

      assert in_panel?(view, "[data-api-key-set]", "已设置")

      for html <- [html, render(view), panel_html(view)], do: refute(html =~ "sk-zai-1")
      refute state(view) =~ "sk-zai-1"
      refute render(view) =~ "复制"
    end

    test "留空不变", ctx do
      zai = zai(ctx)
      {:ok, view, _html} = live(ctx.conn, "#{@path}?panel=edit&id=#{zai.id}")

      submit(
        view,
        %{"name" => "zai-main", "base_url" => zai.base_url, "models" => zai.models},
        %{"api_key" => ""}
      )

      assert {:ok, %{name: "zai-main"}} = ProviderAccounts.get(ctx.alice_scope, zai.id)
      assert stored_key(zai) == "sk-zai-1"
    end

    test "失败不泄露", ctx do
      zai = zai(ctx)
      key = sentinel()
      {:ok, view, _html} = live(ctx.conn, "#{@path}?panel=edit&id=#{zai.id}")

      render_change(view, "account_form_change", %{
        "account" => %{"name" => "zai", "api_key" => key, "base_url" => "ftp://x"}
      })

      refute state(view) =~ key

      html =
        submit(
          view,
          %{"name" => "zai", "base_url" => "http://api.example.com", "models" => zai.models},
          %{"api_key" => key}
        )

      assert in_panel?(view, "#provider-account-form", "只有本机地址可以使用 http")

      assert portal_attr(view, "provider-account-panel", "#provider-account-api-key", "value") ==
               ""

      for html <- [html, render(view), panel_html(view)], do: refute(html =~ key)
      refute state(view) =~ key
      assert stored_key(zai) == "sk-zai-1"

      assert {:ok, %{base_url: "https://api.z.ai/api/anthropic"}} =
               ProviderAccounts.get(ctx.alice_scope, zai.id)
    end

    test "替换密钥", ctx do
      zai = zai(ctx)
      key = sentinel()
      {:ok, view, _html} = live(ctx.conn, "#{@path}?panel=edit&id=#{zai.id}")

      html =
        submit(
          view,
          %{"name" => "zai", "base_url" => zai.base_url, "models" => zai.models},
          %{"api_key" => key}
        )

      assert html =~ "已保存"
      assert stored_key(zai) == key
      refute render(view) =~ key
      refute state(view) =~ key
      assert has_element?(view, "#{row(zai)} [data-api-key]", "已设置")
    end

    test "the key input sits in an ignored container renewed with each opening", ctx do
      zai = zai(ctx)
      {:ok, view, _html} = live(ctx.conn, "#{@path}?panel=edit&id=#{zai.id}")
      assert in_panel?(view, ~s(#provider-account-form-1-api-key[phx-update="ignore"]))

      render_patch(view, @path)
      render_patch(view, "#{@path}?panel=edit&id=#{zai.id}")
      assert in_panel?(view, ~s(#provider-account-form-2-api-key[phx-update="ignore"]))
    end
  end

  describe "删除供应商账号" do
    test "删除未使用的账号", ctx do
      volc = provider_account_fixture(ctx.alice, %{name: "volc"})
      {:ok, view, _html} = live(ctx.conn, @path)

      render_click(view, "ask_delete", %{"id" => to_string(volc.id)})
      assert open?(view, "provider-account-confirm")

      assert in_portal?(view, "provider-account-confirm", "#provider-account-confirm", "删除 volc？")

      assert portal_attr(
               view,
               "provider-account-confirm",
               "#provider-account-confirm-confirm",
               "phx-click"
             ) =~
               ~s("id":#{volc.id})

      html = confirm_delete(view, volc)
      assert html =~ "已删除 volc"
      refute has_element?(view, row(volc))
      assert {:ok, []} = ProviderAccounts.list(ctx.alice_scope)
    end

    test "在使用中不能删", ctx do
      zai = zai(ctx)
      bind(ctx, "claude-zai", zai)
      {:ok, view, _html} = live(ctx.conn, @path)

      assert has_element?(view, "#provider-account-#{zai.id}-delete[aria-disabled]")

      assert has_element?(
               view,
               "#provider-account-#{zai.id}-delete-reason",
               "被 1 个 Agent 使用，不能删除"
             )

      render_click(view, "ask_delete", %{"id" => to_string(zai.id)})
      refute open?(view, "provider-account-confirm")
    end

    test "确认期间被绑定", ctx do
      volc = provider_account_fixture(ctx.alice, %{name: "volc"})
      {:ok, view, _html} = live(ctx.conn, @path)

      render_click(view, "ask_delete", %{"id" => to_string(volc.id)})
      bind(ctx, "claude-volc", volc)
      confirm_delete(view, volc)

      slug = ctx.ws.slug
      assert open?(view, "provider-account-in-use")

      assert in_portal?(
               view,
               "provider-account-in-use",
               "#provider-account-in-use-title",
               "不能删除 volc"
             )

      assert in_portal?(
               view,
               "provider-account-in-use",
               ~s([data-in-use-agent][href="/w/#{slug}/agents/claude-volc"]),
               "#{slug}/claude-volc"
             )

      assert has_element?(view, row(volc))
      assert has_element?(view, "#{row(volc)} [data-agent]", "#{slug}/claude-volc")

      render_click(view, "dismiss_in_use", %{})
      refute open?(view, "provider-account-in-use")
    end

    test "an account already deleted", ctx do
      volc = provider_account_fixture(ctx.alice, %{name: "volc"})
      {:ok, view, _html} = live(ctx.conn, @path)

      render_click(view, "ask_delete", %{"id" => to_string(volc.id)})
      :ok = ProviderAccounts.delete(ctx.alice_scope, volc.id)
      assert confirm_delete(view, volc) =~ "供应商账号已被删除"
      refute has_element?(view, row(volc))
    end
  end

  describe "供应商账号页实时刷新" do
    test "另一个标签页新建", ctx do
      {:ok, view, _html} = live(ctx.conn, @path)
      volc = provider_account_fixture(ctx.alice, %{name: "volc"})
      eventually(fn -> has_element?(view, "#{row(volc)} [data-name]", "volc") end)
    end

    test "编辑中被删除", ctx do
      volc = provider_account_fixture(ctx.alice, %{name: "volc"})
      {:ok, view, _html} = live(ctx.conn, "#{@path}?panel=edit&id=#{volc.id}")

      render_change(view, "account_form_change", %{"account" => %{"name" => "volc-2"}})
      :ok = ProviderAccounts.delete(ctx.alice_scope, volc.id)

      eventually(fn -> in_panel?(view, "#provider-account-form-notice", "volc 已被删除") end)
      assert in_panel?(view, "#provider-account-form-submit[disabled]")

      assert portal_attr(view, "provider-account-panel", "#provider-account-name", "value") ==
               "volc-2"
    end

    test "编辑中被修改", ctx do
      volc = provider_account_fixture(ctx.alice, %{name: "volc"})
      {:ok, view, _html} = live(ctx.conn, "#{@path}?panel=edit&id=#{volc.id}")

      {:ok, _} = ProviderAccounts.update(ctx.alice_scope, volc.id, %{"name" => "volc-x"})

      eventually(fn ->
        in_panel?(view, "#provider-account-form-notice", "volc 已被修改，提交仍以面板中的值为准")
      end)

      refute in_panel?(view, "#provider-account-form-submit[disabled]")
    end

    test "绑定后「使用中」刷新", ctx do
      volc = provider_account_fixture(ctx.alice, %{name: "volc"})
      {:ok, view, _html} = live(ctx.conn, @path)
      refute has_element?(view, "#provider-account-#{volc.id}-delete[aria-disabled]")

      bind(ctx, "claude-volc", volc)
      slug = ctx.ws.slug

      eventually(fn -> has_element?(view, "#{row(volc)} [data-agent]", "#{slug}/claude-volc") end)
      assert has_element?(view, "#provider-account-#{volc.id}-delete[aria-disabled]")
    end
  end
end
