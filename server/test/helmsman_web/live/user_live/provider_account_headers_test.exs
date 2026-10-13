defmodule HelmsmanWeb.UserLive.ProviderAccountHeadersTest do
  @moduledoc """
  Spec web-provider-accounts「Codex 账号的自定义请求头」(add-provider-account-headers
  决策 11): the headers group of the account panel, its write-only values and the
  header names in the list.
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
    %{conn: log_in_user(conn, alice), alice: alice, scope: Scope.for_user(alice)}
  end

  defp sentinel, do: "hv-#{System.unique_integer([:positive])}"

  defp codex_attrs(extra) do
    Map.merge(
      %{
        name: "apim",
        cli: "codex",
        base_url: "https://gw.example.com/openai/v1",
        api_key: "k-1",
        models: %{"default" => "gpt-6-luna"}
      },
      extra
    )
  end

  defp apim(ctx, values) do
    provider_account_fixture(
      ctx.alice,
      codex_attrs(%{
        headers: %{"Ocp-Apim-Subscription-Key" => values.s, "user" => values.u}
      })
    )
  end

  defp params(extra) do
    Map.merge(
      %{
        "name" => "apim",
        "cli" => "codex",
        "base_url" => "https://gw.example.com/openai/v1",
        "models" => %{"default" => "gpt-6-luna"}
      },
      extra
    )
  end

  # The rendered parameter shape: names in `new`, values under `headers_password`.
  defp rows(rows, existing \\ %{}) do
    %{
      "new" => Map.new(rows, fn {id, name, _value} -> {id, %{"name" => name}} end),
      "headers_password" => %{
        "new" => Map.new(rows, fn {id, _name, value} -> {id, value} end),
        "existing" => existing
      }
    }
  end

  defp change(view, params),
    do: render_change(view, "account_form_change", %{"account" => params})

  defp submit(view, params),
    do: render_submit(view, "account_form_submit", %{"account" => params})

  defp add_row(view), do: render_click(view, "account_form_header_add", %{})

  defp in_panel?(view, selector, text \\ nil), do: in_portal?(view, @panel, selector, text)

  defp panel_html(view), do: view |> portal(@panel) |> LazyHTML.to_html()

  defp state(view), do: view.pid |> :sys.get_state() |> inspect(limit: :infinity)

  defp new_codex(ctx) do
    {:ok, view, _html} = live(ctx.conn, @path <> "?panel=new")
    change(view, %{"cli" => "codex"})
    view
  end

  defp refute_leak(view, values, extra_html \\ []) do
    for html <- [render(view), panel_html(view) | extra_html], value <- values do
      refute html =~ value
    end

    for value <- values, do: refute(state(view) =~ value)
  end

  describe "the headers group" do
    test "only Codex accounts have it", ctx do
      {:ok, view, _html} = live(ctx.conn, @path <> "?panel=new")
      refute in_panel?(view, "#provider-account-headers")

      change(view, %{"cli" => "codex"})
      assert in_panel?(view, "#provider-account-headers legend", "自定义请求头")
      assert in_panel?(view, "#provider-account-headers", "值与密钥同样只写不读；只有需要额外请求头的网关才填")

      add_row(view)
      assert in_panel?(view, "[data-new-header]")

      change(view, Map.put(rows([{"1", "user", "x"}]), "cli", "claude"))
      refute in_panel?(view, "#provider-account-headers")
      refute in_panel?(view, "[data-new-header]")

      change(view, %{"cli" => "codex"})
      refute in_panel?(view, "[data-new-header]")
    end

    test "a Claude Code edit panel has none", ctx do
      zai = provider_account_fixture(ctx.alice, %{name: "zai"})
      {:ok, view, _html} = live(ctx.conn, "#{@path}?panel=edit&id=#{zai.id}")
      assert open?(view, @panel)
      refute in_panel?(view, "#provider-account-headers")
    end

    test "new rows: password values in ignored containers, removable", ctx do
      view = new_codex(ctx)
      add_row(view)
      add_row(view)

      assert in_panel?(view, ~s(#provider-account-form-1-header-new-1[phx-update="ignore"]))
      assert in_panel?(view, ~s(#provider-account-form-1-header-new-2[phx-update="ignore"]))

      assert portal_attr(view, @panel, "#provider-account-header-new-1-value", "type") ==
               "password"

      assert portal_attr(view, @panel, "#provider-account-header-new-1-value", "value") == ""

      render_click(view, "account_form_header_remove", %{"row" => "1"})
      refute in_panel?(view, "#provider-account-header-new-1")
      assert in_panel?(view, "#provider-account-header-new-2")
    end

    test "最多 8 个 new rows", ctx do
      view = new_codex(ctx)
      for _ <- 1..7, do: add_row(view)
      refute in_panel?(view, "#provider-account-headers-limit")
      add_row(view)

      assert portal_attr(view, @panel, "#provider-account-header-add", "aria-disabled") == "true"
      assert in_panel?(view, "#provider-account-headers-limit", "最多 8 个请求头")

      add_row(view)
      assert view |> portal(@panel) |> LazyHTML.query("[data-new-header]") |> Enum.count() == 8

      render_click(view, "account_form_header_remove", %{"row" => "3"})
      refute in_panel?(view, "#provider-account-headers-limit")
    end

    test "typing keeps names but never values", ctx do
      view = new_codex(ctx)
      add_row(view)
      value = sentinel()

      change(view, rows([{"1", "user", value}]))

      assert portal_attr(view, @panel, "#provider-account-header-new-1-name", "value") == "user"
      assert portal_attr(view, @panel, "#provider-account-header-new-1-value", "value") == ""
      refute_leak(view, [value])
    end

    test "a failed submit: error under the group, names kept, no value anywhere", ctx do
      view = new_codex(ctx)
      add_row(view)
      add_row(view)
      a = sentinel()
      b = sentinel()

      html =
        submit(
          view,
          params(Map.put(rows([{"1", "user", a}, {"2", "User", b}]), "api_key", sentinel()))
        )

      assert open?(view, @panel)
      assert in_panel?(view, "#provider-account-headers-error", "请求头名字重复：user")
      assert portal_attr(view, @panel, "#provider-account-header-new-2-name", "value") == "User"
      assert {:ok, []} = ProviderAccounts.list(ctx.scope)
      refute_leak(view, [a, b], [html])

      change(view, %{"new" => %{"2" => %{"name" => "user-2"}}})
      refute in_panel?(view, "#provider-account-headers-error")
    end
  end

  describe "saved headers" do
    test "新建带请求头的 Codex 账号", ctx do
      view = new_codex(ctx)
      add_row(view)
      add_row(view)
      s = sentinel()
      u = sentinel()

      html =
        submit(
          view,
          params(
            Map.put(
              rows([{"1", "Ocp-Apim-Subscription-Key", s}, {"2", "user", u}]),
              "api_key",
              sentinel()
            )
          )
        )

      refute open?(view, @panel)
      {:ok, [apim]} = ProviderAccounts.list(ctx.scope)
      assert Enum.sort(apim.headers) == ["Ocp-Apim-Subscription-Key", "user"]
      assert has_element?(view, "#provider-account-#{apim.id} [data-header]", "user")

      assert has_element?(
               view,
               "#provider-account-#{apim.id} [data-header]",
               "Ocp-Apim-Subscription-Key"
             )

      refute_leak(view, [s, u], [html])
    end

    test "编辑不回填", ctx do
      values = %{s: sentinel(), u: sentinel()}
      apim = apim(ctx, values)
      {:ok, view, html} = live(ctx.conn, "#{@path}?panel=edit&id=#{apim.id}")

      for name <- ["Ocp-Apim-Subscription-Key", "user"] do
        assert in_panel?(view, ~s(#provider-account-headers-stored [data-header="#{name}"]), name)
      end

      assert in_panel?(view, "#provider-account-headers-stored [data-header-set]", "已设置")
      assert portal_attr(view, @panel, "#provider-account-header-0-value", "value") == ""
      assert portal_attr(view, @panel, "#provider-account-header-0-value", "type") == "password"

      assert portal_attr(view, @panel, "#provider-account-header-0-value", "name") ==
               "account[headers_password][existing][0]"

      refute_leak(view, [values.s, values.u], [html])
    end

    test "替换一个值、删除一个", ctx do
      values = %{s: sentinel(), u: sentinel()}
      apim = apim(ctx, values)
      {:ok, view, _html} = live(ctx.conn, "#{@path}?panel=edit&id=#{apim.id}")
      i = Enum.find_index(apim.headers, &(&1 == "user"))
      j = 1 - i
      u2 = sentinel()

      render_click(view, "account_form_header_delete", %{"name" => "Ocp-Apim-Subscription-Key"})
      assert in_panel?(view, ~s(#provider-account-header-#{j}[data-deleted]), "保存后删除")

      html = submit(view, params(rows([], %{"#{i}" => u2, "#{j}" => ""})))

      assert html =~ "已保存"
      assert {:ok, %{headers: ["user"]}} = ProviderAccounts.get(ctx.scope, apim.id)
      refute_leak(view, [u2, values.u, values.s], [html])
    end

    test "不改动请求头", ctx do
      values = %{s: sentinel(), u: sentinel()}
      apim = apim(ctx, values)
      {:ok, view, _html} = live(ctx.conn, "#{@path}?panel=edit&id=#{apim.id}")

      submit(view, params(Map.put(rows([], %{"0" => "", "1" => ""}), "name", "apim-2")))

      assert {:ok, %{name: "apim-2", headers: headers}} = ProviderAccounts.get(ctx.scope, apim.id)
      assert Enum.sort(headers) == ["Ocp-Apim-Subscription-Key", "user"]
    end

    test "错误显示在分组下且不泄露", ctx do
      view = new_codex(ctx)
      add_row(view)
      secret = "x-secret-1"

      html =
        submit(
          view,
          params(Map.put(rows([{"1", "authorization", secret}]), "api_key", sentinel()))
        )

      assert open?(view, @panel)
      assert in_panel?(view, "#provider-account-headers-error", "authorization")
      assert {:ok, []} = ProviderAccounts.list(ctx.scope)
      refute_leak(view, [secret], [html])
    end

    test "最多 8 个: stored headers count, a deletion mark frees a place", ctx do
      headers = Map.new(1..6, &{"x-h#{&1}", "v-#{&1}"})
      acct = provider_account_fixture(ctx.alice, codex_attrs(%{headers: headers}))
      {:ok, view, _html} = live(ctx.conn, "#{@path}?panel=edit&id=#{acct.id}")

      add_row(view)
      add_row(view)
      assert portal_attr(view, @panel, "#provider-account-header-add", "aria-disabled") == "true"
      assert in_panel?(view, "#provider-account-headers-limit", "最多 8 个请求头")

      render_click(view, "account_form_header_delete", %{"name" => "x-h1"})
      refute in_panel?(view, "#provider-account-headers-limit")

      render_click(view, "account_form_header_delete", %{"name" => "x-h1"})
      assert in_panel?(view, "#provider-account-headers-limit")
    end
  end
end
