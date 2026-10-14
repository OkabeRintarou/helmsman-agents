defmodule HelmsmanWeb.UserLive.ProviderAccountIconTest do
  @moduledoc """
  web-provider-accounts「供应商账号的图标选择与显示」(add-actor-avatars D19): the 图标
  field (自动 with the inferred icon, 厂商 / 平台 groups with a filter) and the icons of
  the account list, with the account's stored `icon`.
  """
  use HelmsmanWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import HelmsmanWeb.PortalHelpers
  import Helmsman.AccountsFixtures
  import Helmsman.ProviderAccountsFixtures

  alias Helmsman.Accounts.Scope
  alias Helmsman.ProviderAccounts

  @path "/users/settings/provider-accounts"
  @panel "provider-account-panel"

  setup %{conn: conn} do
    alice = user_fixture(%{display_name: "alice"})
    %{conn: log_in_user(conn, alice), alice: alice}
  end

  defp change(view, params),
    do: render_change(view, "account_form_change", %{"account" => params})

  defp choice(view), do: portal_text(view, @panel, "[data-icon-choice]")

  defp shown(view),
    do: portal_attr(view, @panel, "#provider-account-icon-trigger [data-brand]", "data-brand")

  test "自动 infers from the address and follows it (spec 自动推断)", ctx do
    {:ok, view, _} = live(ctx.conn, @path <> "?panel=new")
    assert choice(view) =~ "自动（Anthropic）"

    change(view, %{"cli" => "claude", "base_url" => "https://api.z.ai/api/anthropic"})
    assert choice(view) =~ "自动（Z.ai）"
    assert shown(view) == "zai"
    assert portal_attr(view, @panel, "input[name='account[icon]']", "value") == ""

    change(view, %{"cli" => "codex", "base_url" => ""})
    assert choice(view) =~ "自动（OpenAI）"
  end

  test "an unknown address is 未识别 (spec 未识别)", ctx do
    {:ok, view, _} = live(ctx.conn, @path <> "?panel=new")
    change(view, %{"base_url" => "https://llm.internal.corp/v1"})
    assert choice(view) =~ "自动（未识别）"
    assert shown(view) == "none"
  end

  test "a local Ollama is inferred from the port (spec 本地 Ollama)", ctx do
    {:ok, view, _} = live(ctx.conn, @path <> "?panel=new")
    change(view, %{"base_url" => "http://localhost:11434/v1"})
    assert choice(view) =~ "自动（Ollama）"
  end

  test "choosing an icon overrides the inference (spec 手动选择覆盖推断)", ctx do
    {:ok, view, _} = live(ctx.conn, @path <> "?panel=new")
    change(view, %{"base_url" => "https://my-proxy.example.com/v1"})

    assert in_portal?(view, @panel, "#provider-account-icon-zhipu", "智谱")
    assert in_portal?(view, @panel, "#provider-account-icon-openrouter [data-brand=openrouter]")
    assert in_portal?(view, @panel, "#provider-account-icon-filter")

    render_click(view, "account_form_icon", %{"icon" => "openrouter"})
    assert choice(view) =~ "OpenRouter"
    assert shown(view) == "openrouter"
    assert portal_attr(view, @panel, "input[name='account[icon]']", "value") == "openrouter"

    # A later change of the form keeps the choice; unknown keys are refused.
    change(view, %{"name" => "proxy", "icon" => "openrouter"})
    assert shown(view) == "openrouter"
    render_click(view, "account_form_icon", %{"icon" => "foo"})
    assert choice(view) =~ "自动（未识别）"
  end

  test "the account list shows the inferred icon", ctx do
    provider_account_fixture(ctx.alice, %{
      name: "zai",
      base_url: "https://api.z.ai/api/anthropic",
      models: %{"default" => "glm-5.3"}
    })

    {:ok, view, _} = live(ctx.conn, @path)
    assert has_element?(view, "#provider-accounts [data-account-icon=zai]")
    # The model takes the account's family (zai, not zhipu).
    assert has_element?(view, "#provider-accounts [data-default-model] [data-model-vendor=zai]")
  end

  test "the chosen icon is saved, shown in the list, and 自动 clears it", ctx do
    {:ok, view, _} = live(ctx.conn, @path <> "?panel=new")

    change(view, %{
      "name" => "proxy",
      "cli" => "claude",
      "base_url" => "https://my-proxy.example.com/v1"
    })

    render_click(view, "account_form_icon", %{"icon" => "openrouter"})

    render_submit(view, "account_form_submit", %{
      "account" => %{
        "name" => "proxy",
        "cli" => "claude",
        "base_url" => "https://my-proxy.example.com/v1",
        "icon" => "openrouter",
        "api_key" => "sk-test-icon"
      }
    })

    {:ok, [account]} = ProviderAccounts.list(Scope.for_user(ctx.alice))

    assert account.icon == "openrouter"
    assert has_element?(view, "#provider-account-#{account.id} [data-account-icon=openrouter]")

    {:ok, view, _} = live(ctx.conn, @path <> "?panel=edit&id=#{account.id}")
    assert choice(view) =~ "OpenRouter"
    render_click(view, "account_form_icon", %{"icon" => ""})

    render_submit(view, "account_form_submit", %{
      "account" => %{
        "name" => "proxy",
        "base_url" => "https://my-proxy.example.com/v1",
        "icon" => ""
      }
    })

    {:ok, [account]} = ProviderAccounts.list(Scope.for_user(ctx.alice))
    assert account.icon == nil
    assert has_element?(view, "#provider-account-#{account.id} [data-account-icon=none]")
  end

  test "a stored key outside the tables stays neutral, never inferred (spec 未知键)", ctx do
    assert HelmsmanWeb.ProviderAccountComponents.account_icon(%{
             icon: "foo",
             base_url: "https://api.openai.com/v1",
             cli: "codex"
           }) == nil

    assert HelmsmanWeb.ProviderAccountComponents.account_icon(%{
             icon: nil,
             base_url: "https://api.openai.com/v1",
             cli: "codex"
           }) == "openai"

    account =
      provider_account_fixture(ctx.alice, %{
        name: "odd",
        base_url: "https://api.anthropic.com",
        icon: "foo"
      })

    {:ok, view, _} = live(ctx.conn, @path)
    assert has_element?(view, "#provider-account-#{account.id} [data-account-icon=none]")

    {:ok, view, _} = live(ctx.conn, @path <> "?panel=edit&id=#{account.id}")
    assert choice(view) =~ "未知图标（foo）"
    assert shown(view) == "none"

    # Other changes keep the stored key.
    change(view, %{"name" => "odd2", "icon" => "foo"})
    assert portal_attr(view, @panel, "input[name='account[icon]']", "value") == "foo"
  end

  describe "summaries of Agent and run views (host + port, domain-request-2 R9/R10)" do
    alias HelmsmanWeb.ProviderAccountComponents, as: Components

    test "the icon is inferred from the host and the port" do
      summary = %{id: 1, name: "local", cli: "claude", host: "localhost", port: 11_434, icon: nil}
      assert Components.account_icon(summary) == "ollama"
      assert Components.account_icon(%{summary | host: "::1"}) == "ollama"
      assert Components.account_icon(%{summary | host: "api.z.ai", port: nil}) == "zai"
      assert Components.account_icon(%{summary | host: "api.z.ai", port: 443}) == "zai"
      assert Components.account_icon(%{summary | icon: "openrouter"}) == "openrouter"
      assert Components.account_icon(%{summary | icon: "foo"}) == nil
    end

    test "the summary shows the icon, the name and the host" do
      html =
        render_component(&Components.account_summary/1,
          account: %{
            id: 1,
            name: "local",
            cli: "claude",
            host: "localhost",
            port: 11_434,
            icon: nil
          }
        )

      assert html =~ ~s(data-account-icon="ollama")
      assert html =~ ~s(aria-label="Ollama")
      assert html =~ "local"
    end
  end
end
